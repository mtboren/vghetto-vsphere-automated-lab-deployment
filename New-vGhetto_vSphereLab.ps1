<#  .Description
    PowerCLI script to deploy a fully functional vSphere 6.0 or 6.5 lab consisting of 3
    Nested ESXi hosts enable w/vSAN + VCSA of the corresponding vSphere version.
    Expects either a target vCenter or a single physical ESXi host as the endpoint, and
    all four of the VMs will be deployed to physical ESXi host.

    .Notes
    Author: William Lam
    Website: www.virtuallyghetto.com
    Reference: http://www.virtuallyghetto.com/2016/11/vghetto-automated-vsphere-lab-deployment-for-vsphere-6-0u2-vsphere-6-5.html
    Credit: Thanks to Alan Renouf as I borrowed some of his PCLI code snippets :)

    Changelog
    22 Nov 2016
      * Automatically handle Nested ESXi on vSAN
    20 Jan 2017
      * Resolved "Another task in progress" thanks to Jason M
    12 Feb 2017
      * Support for deploying to VC Target
      * Support for enabling SSH on VCSA
      * Added option to auto-create vApp Container for VMs
      * Added pre-check for required files
    17 Feb 2017
      * Added missing dvFilter param to eth1 (missing in Nested ESXi OVA)
    21 Feb 2017
      * Support for deploying NSX 6.3 & registering with vCenter Server
      * Support for updating Nested ESXi VM to ESXi 6.5a (required for NSX 6.3)
      * Support for VDS + VXLAN VMkernel configuration (required for NSX 6.3)
      * Support for "Private" Portgroup on eth1 for Nested ESXi VM used for VXLAN traffic (required for NSX 6.3)
      * Support for both Virtual & Distributed Portgroup on $VMNetwork
      * Support for adding ESXi hosts into VC using DNS name (disabled by default)
      * Added CPU/MEM/Storage resource requirements in confirmation screen

    .Example
    (Get-Content -Raw C:\Temp\myParamsForNewVsphereLab.json) | ConvertFrom-Json | New-vGhetto_vSphereLab.ps1
    Take all parameters specified in the JSON file and use them in calling New-vGhetto_vSphereLab.ps1
    This takes the JSON, converts it to an object with properties and values, and since the property names match the parameter names and the parameters take value from pipeline by property name, it's a match!  The parameter is specified!

    .Example
    Get-Help -Full New-vGhetto_vSphereLab.ps1
    Get the full, PowerShell-like (because it _is_ PowerShell help!) help for this script, with descriptions and default-value information for all parameters, with examples, etc.  What a wonderful gift to the PowerShell user:  they can get help in the way that they do with everything else in PowerShell.
#>
[CmdletBinding(DefaultParameterSetName="Default")]
param (
    ## The address of the physical ESXi host or vCenter Server to which to deploy vSphere lab
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VIServer = "vcenter.primp-industries.com",
    ## Credential with which to connect to ESXi host or vCenter, on which to then deploy new vSphere lab
    [ValidateNotNullOrEmpty()][System.Management.Automation.PSCredential]$Credential = (Get-Credential -Message "Credential to use for initially connecting to vCenter or ESXi host for vSphere lab deployment"),
    ## Switch: Deploy the new lab as self-managed? Not specifying means lab will deployed as "Standard". Standard deployment creates all VMs on physical ESXi host(s), whereas self-managed creates just the vESXi VMs on physical ESXi host(s), and then deploys the VCSA on one of the new vESXi hosts on said vESXi host's new VSAN storage.
    #   Notice: deploying as self-managed requires larger resource settings on the vESXi VMs (memory, disk) to be able to house the VCSA VM, so the actual sizes used for the vESXi VMs may be larger than the settings specified by parameters -NestedESXivMemGB, -NestedESXiCachingvDiskGB, and -NestedESXiCapacityvDiskGB. See the pre-deployment summary for sizing that will be used for vESXi hosts
    [parameter(ValueFromPipelineByPropertyName=$true)][Switch]$DeployAsSelfManaged = $false,

    ## Full path to the OVA of the Nested ESXi virtual appliance. Examples: "C:\temp\Nested_ESXi6.5_Appliance_Template_v1.ova" or "C:\temp\Nested_ESXi6.x_Appliance_Template_v5.ova"
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -Path $_})][string]$NestedESXiApplianceOVA,
    ## Full Path to where the contents of the VCSA 6.* ISO can be accessed. Say, either a folder into which the ISO was extracted, or a drive letter as which the ISO is mounted. For example, "C:\Temp\VMware-VCSA-all-6.5.0-4944578" or "D:\"
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -PathType Container -Path $_})][string]$VCSAInstallerPath,
    ## Full path to the vmw-ESXi-6.5.0-metadata.zip file in the full, extracted ESXi 6.5a VMHost offline update bundle. If not specified, the new ESXi hosts will not be updated to this new version. The offline bundle zip file should be extracted into a folder that matches the update profile's name (e.g., "ESXi650-201701001"). Example:  C:\temp\ESXi650-201701001\vmw-ESXi-6.5.0-metadata.zip
    [parameter(ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -Path $_})][string]$ESXi65aOfflineBundle,

    ## Information about the nested ESXi VMs to deploy. Expects a hashtable with ESXi host shortnames as keys, and the corresponding IP addresses as values
    [parameter(ValueFromPipelineByPropertyName=$true)][PSObject]$NestedESXiHostnameToIPs = @{
        "vesxi65-1" = "172.30.0.171"
        "vesxi65-2" = "172.30.0.172"
        "vesxi65-3" = "172.30.0.173"
    },

    ## Nested ESXi VM Resources -- number of vCPU for each new ESXi VM
    [parameter(ValueFromPipelineByPropertyName=$true)][int]$NestedESXivCPU = 2,
    # Nested ESXi VM Resources -- amount of memory, in GB, for each new ESXi VM
    [parameter(ValueFromPipelineByPropertyName=$true)][int]$NestedESXivMemGB = 6,
    # Nested ESXi VM Resources -- size of caching vDisk, in GB
    [parameter(ValueFromPipelineByPropertyName=$true)][int]$NestedESXiCachingvDiskGB = 4,
    # Nested ESXi VM Resources -- size of capacity vDisk, in GB
    [parameter(ValueFromPipelineByPropertyName=$true)][int]$NestedESXiCapacityvDiskGB = 8,

    ## VCSA Deployment Configuration -- the "size" setting to use for determining the number of CPU and the amount of memory/disk for the new VCSA VM. Defaults to "Tiny", and accepts one of "Tiny", "Small", "Medium", "Large", or "XLarge".  Some sizing info:  the vCPU values used for these sizes, respectively, are 2, 4, 8, 16, and 24
    [parameter(ValueFromPipelineByPropertyName=$true)][ValidateSet("Tiny", "Small", "Medium", "Large", "XLarge")][string]$VCSADeploymentSize = "Tiny",
    ## VCSA Deployment Configuration -- VM object name for the new VCSA VM
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VCSADisplayName = "vcenter65-1",
    ## VCSA Deployment Configuration -- IP address to assign to the new VCSA
    [parameter(ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VCSAIPAddress = "172.30.0.170",
    ## VCSA Deployment Configuration -- Guest hostname (FQDN) for the new VCSA VM. Change to IP if you don't have valid DNS services in play
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VCSAHostname = "vcenter65-1.primp-industries.com",
    ## VCSA Deployment Configuration -- VCSA VM guest networking subnet mask prefix length. Like, "24", for example
    [parameter(ValueFromPipelineByPropertyName=$true)][int]$VCSAPrefix = 24,
    ## VCSA Deployment Configuration -- the domain name for the new SSO site
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VCSASSODomainName = "vghetto.local",
    ## VCSA Deployment Configuration -- the name of the new SSO site
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VCSASSOSiteName = "virtuallyGhetto",
    ## VCSA Deployment Configuration -- the SSO administrator's password
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VCSASSOPassword = "VMware1!",
    ## VCSA Deployment Configuration -- the password for the 'root' user in the VCSA guest OS
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VCSARootPassword = "VMware1!",
    ## Switch:  enable SSH on VCSA VM?  Defaults to $true
    [parameter(ValueFromPipelineByPropertyName=$true)][Switch]$VCSASSHEnable = $true,

    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- name of virtual portgroup to which to connect VMs' primary network adapter
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][string]$VMNetwork,
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- datastore or datastorecluster on which to create new VMs
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][string]$VMDatastore = "himalaya-local-SATA-dc3500-0",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- subnet mask to use in Guest OS networking configuration
    [parameter(ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VMNetmask = "255.255.255.0",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- default gateway to use in Guest OS networking configuration
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VMGateway = "172.30.0.1",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- IP of DNS server(s) to use in Guest OS networking configuration. As of now, newly created vESXi hosts will use just the first DNS server IP here.
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress[]]$VMDNS,
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- NTP server to use
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VMNTP = "pool.ntp.org",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- guest OS password
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VMPassword = "vmware123",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- DNS domain name for guest OS
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VMDomain = "primp-industries.com",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- Syslog server address
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VMSyslog = "mysyslogserver.primp-industries.com",

    ## Applicable to Nested ESXi only -- Switch:  enable SSH access? Default is $true
    [parameter(ValueFromPipelineByPropertyName=$true)][Switch]$VMSSH = $true,
    ## Applicable to Nested ESXi only -- Switch:  "Automatically create local VMFS Datastore (datastore1)"? Default is $false
    [parameter(ValueFromPipelineByPropertyName=$true)][Switch]$VMVMFS,

    ## Name of vSphere cluster in which to create new VMs. Only applicable when Deployment Target is "vCenter"
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$VMCluster = "Primp-Cluster",
    ## Name for new vSphere Datacenter when VCSA is deployed
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$NewVCDatacenterName = "Datacenter",
    ## Name for new vSphere Cluster when VCSA is deployed
    [parameter(ValueFromPipelineByPropertyName=$true)][string]$NewVCVSANClusterName = "VSAN-Cluster",

    ## Full path to the NSX Manager 6.3 OVA, if installing NSX in this new lab deployment is desired. If not specified, no NSX components will be deployed.  Example: C:\temp\VMware-NSX-Manager-6.3.0-5007049.ova
    [parameter(Mandatory=$true, ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -Path $_})][string]$NSXOVA,
    ## NSX Manager Configuration -- VM object name for the new NSX Manager VM
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][string]$NSXDisplayName = "nsx63-1",
    ## NSX Manager Configuration -- Number of vCPU to use for the new NSX Manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][int]$NSXvCPU = 2,
    ## Amount of memory, in GB, to use for the new NSX Manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][int]$NSXvMemGB = 8,
    ## Guest OS hostname for the new NSX manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][string]$NSXHostname = "nsx63-1.primp-industries.com",
    ## Guest OS IP address for the new NSX manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$NSXIPAddress = "172.30.0.250",
    ## Guest OS IP address for the new NSX manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$NSXNetmask = "255.255.255.0",
    ## Default gateway to use in Guest OS networking configuration for the new NSX manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$NSXGateway = "172.30.0.1",
    ## Switch:  enable SSH access to new NSX Manager? Default is $true
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][Switch]$NSXSSHEnable = $true,
    ## Switch:  enable the Customer Experience Improvement Program in the new NSX Manager? Default is $false
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][Switch]$NSXCEIPEnable,
    ## Password for the UI on the new NSX Manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][string]$NSXUIPassword = "VMw@re123!",
    ## Password for the CLI on the new NSX Manager
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][string]$NSXCLIPassword = "VMw@re123!",

    ## VDS / VXLAN Configurations -- name of virtual portgroup to use for network adapter for private VXLAN on NSX Manager VM
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][string]$PrivateVXLANVMNetwork = "dv-private-network",
    ## VDS / VXLAN Configurations -- name to use for when creating new VDSwitch in new virtual datacenter for use by NSX
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][string]$VDSName = "VDS-6.5",
    ## VDS / VXLAN Configurations -- name to use for when creating new VXLAN VDPortgroup on new VDSwitch for NSX
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][string]$VXLANDVPortgroup = "VXLAN",
    ## The Network subnet to use for making the IP address for the VXLAN VMKernel VMHost network adapter. Expects an address in the form 172.16.66.0. The last octet will be replace with the value of the last octet of the VMHost on which the VMKernel portgroup is being created.
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VXLANSubnet = "172.16.66.0",
    ## The subnet mask to use for making the IP configuration for the VXLAN VMKernel VMHost network adapter. For example, "255.255.255.0"
    [parameter(ParameterSetName="IncludeNSXInDeployment", ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VXLANNetmask = "255.255.255.0",

    ## Switch: add new ESXi hosts to new vCenter by their DNS name? Only do so if you have valid DNS entries (forward/reverse) for ESXi hostnames. Else, the new ESXi hosts are added to the new vCenter by their IP addresses
    [parameter(ValueFromPipelineByPropertyName=$true)][Switch]$AddHostByDnsName
) ## end param

begin {
    $StartTime = Get-Date

    ## hashtable for VCSA "size" name to resource sizing correlation
    $vcsaSize2MemoryStorageMap = @{
        tiny   = @{cpu = 2;  mem = 10; disk = 250}
        small  = @{cpu = 4;  mem = 16; disk = 290}
        medium = @{cpu = 8;  mem = 24; disk = 425}
        large  = @{cpu = 16; mem = 32; disk = 640}
        xlarge = @{cpu = 24; mem = 48; disk = 980}
    } ## end config hashtable
    ## hashtable for vESXi sizing minimums, to be use if lab deployment is of "self-managed" type (vESXi hosts will need to be bigger to be able to house a VCSA)
    $hshMinVESXiSizesForSelfManaged = @{
        vEsxiMemGB = 32
        vsanCachingVDiskGB = 16
        vsanCapacityVDiskGB = 200
    } ## end hashtable

    ## import these modules if not already imported in this PowerShell session
    "VMware.VimAutomation.Core", "VMware.VimAutomation.Vds", "VMware.VimAutomation.Storage" | Foreach-Object {if (-not (Get-Module -Name $_ -ErrorAction:SilentlyContinue)) {Import-Module -Name $_}}

    ## function to write message to a logger, which happens to send the messages both to the PowerShell Host console and to a log file
    Function Write-MyLogger {
        param (
            ## Message to be written to given locations
            [Parameter(Mandatory=$true)][String]$Message,
            ## Filepath to the log file to which to write as a part of this logging operation. Like "mylogfile.log" or "c:\temp\logdest.txt"
            [Parameter(Mandatory=$true)][String]$LogFilePath,
            ## Date/time format string to use for timestamp portion of log entries. Defaults to a re-consumable format (a format that can then be consumed again by Get-Date to create a corresponding datetime object) See https://msdn.microsoft.com/en-us/library/8kb3ddd4(v=vs.110).aspx and https://msdn.microsoft.com/en-us/library/az4se3k1(v=vs.110).aspx for format string information
            [String]$DateTimeFormat = "dd-MMM-yyyy HH:mm:ss"
        ) ## end param

        $timeStamp = Get-Date -Format $DateTimeFormat

        Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
        Write-Host -ForegroundColor Green " $message"
        "[$timeStamp] $message" | Out-File -Append -LiteralPath $LogFilePath
    } ## end function

    ## Helper function to get version of VCSA to be installed by inspecting the install media itself (say, some files on it). Returns [System.Version] of version found on media, or $null if cannot determine
    function _Get-VCSAVersionFromMedia {
        param (
            ## Path to top level of VCSA install media (like, mounted ISO drive path, or top-level folder extracted ISO, for example)
            [parameter(Mandatory=$true)][ValidateScript({Test-Path -PathType Container -Path $_})][string]$VCSAMediaRootPath
        ) ## end param
        ## check the "readme.txt" file at the root of the VCSA install media -- there is a version-like statement on the second line of the file
        # $strMajorAndMinorFromReadme = if ((Get-Content -Path "$VCSAMediaRootPath\readme.txt" | Select-Object -First 3 | Select-String "VMWARE vCenter Server Appliance").Line -match ".+(?<ver>\d\.\d)$") {$Matches.ver}
        ## check the "version.txt" file at the in the "\vcsa\." folder on the VCSA install media -- it contains version info, as the filename might suggest
        #   contents are something like, "VMware-vCenter-Server-Appliance-6.5.0.5200-4944578"; this regex match grabs the "6.5.0" portion, for example
        # if ((Get-Content -Path "$VCSAMediaRootPath\vcsa\version.txt") -match "VMware-vCenter-Server-Appliance-(?<verFromVersion>(\d\.){2}\d)\..+") {
        if ((Get-Content -Path "$VCSAMediaRootPath\vcsa\version.txt") -match "VMware-vCenter-Server-Appliance-(?<verMajorAndMinorFromVersionString>\d\.\d)\.\d\..+") {
            Return [System.Version]$Matches.verMajorAndMinorFromVersionString
        } else {Throw "Unable to determine VCSA install media major/minor version from and version file therein (at \vcsa\version.txt). Is this the full content of the VCSA install media?"}
    } ## end fn

    ## Helper function for writing out configuration information to host, with some consistency and coloration. Uses Write-Host in one of the only good ways it should be used: displaying information to console for interactive consumption
    function _Write-ConfigMessageToHost {
        param(
            ## The header line for this config message section. If none specified, no section "header" line written
            [string]$HeaderLine,
            ## The "body" of the message, with "category" and "value" as the key/value pairs. Can be either a System.Collections.Hashtable or a System.Collections.Specialized.OrderedDictionary
            [parameter(Mandatory=$true)][PSObject]$MessageBodyInfo
        ) ## end param
        if ($PSBoundParameters.ContainsKey("HeaderLine")) {Write-Host -ForegroundColor Yellow "---- $HeaderLine ----"}
        ## get the length of the longest message body "category" string (the longest key string in the hashtable), to be used for space-padding the column
        $intLongestCategoryName = ($MessageBodyInfo.Keys | Measure-Object -Maximum -Property Length).Maximum
        $MessageBodyInfo.Keys | Foreach-Object {
            $strThisKey = $_
            ## write, in green, the category info, space-padded to longer than the longest category info in the hashtable (for uniform width of column 0 in output)
            Write-Host -NoNewline -ForegroundColor Green ("{0,-$($intLongestCategoryName + 1)}: " -f $strThisKey)
            Write-Host -ForegroundColor White $MessageBodyInfo[$strThisKey]
        } ## end foreach-object
        ## add trailing newline
        Write-Host
    } ## end fn

    ## items to specify whether particular sections of the code are executed (for use in working on this script itself, mostly -- should generally all be $true when script is in "normal" functioning mode)
    $preCheck = $confirmDeployment = $true
    $deployNestedESXiVMs = $bootStrapFirstNestedESXiVM = $deployVCSA = $false
    $setupNewVC = $addESXiHostsToVC = $configureVSANDiskGroups = $clearVSANHealthCheckAlarm = $setupVXLAN = $configureNSX = $moveVMsIntovApp = $true
} ## end begin

process {
    ## determine the version of VCSA to be installed
    $verVSphereVersion = _Get-VCSAVersionFromMedia -VCSAMediaRootPath $VCSAInstallerPath
    ## filespec of file to which to write additional log entries
    $verboseLogFile = "vsphere${verVSphereVersion}-vghetto-lab-deployment.log"
    ## date/time format string to use for timestamps for logging-like entries/strings
    $strLoggingDatetimeFormatString = "dd-MMM-yyyy HH:mm:ss"
    ## make the Write-MyLogger function always use the given log file as the value for parameter -LogFilePath, unless explicitly overridden. See "about_Parameters_Default_Values" for lots of info about $PSDefaultParameterValues, which is a System.Management.Automation.DefaultParameterDictionary
    $PSDefaultParameterValues["Write-MyLogger:LogFilePath"] = $verboseLogFile
    ## make the Write-MyLogger function always use the given date/time format string for parameter -DateTimeFormat, unless explicitly overridden. While the function already provides a default value, adding here for ease of changing by just updating the corresponding variable
    $PSDefaultParameterValues["Write-MyLogger:DateTimeFormat"] = $strLoggingDatetimeFormatString
    ## create an eight-character string from lower- and upper alpha characters, for use in creating unique vApp name
    $random_string = -join ([char]"a"..[char]"z" + [char]"A"..[char]"Z" | Get-Random -Count 8 | Foreach-Object {[char]$_})
    $VAppName = "vGhetto-Nested-vSphere-Lab-$verVSphereVersion-$random_string"

    ## determine sizing to use for vESXi hosts -- if Standard deployment type, just use params passed; if "self-managed", need to be at least of given size, so may need to use larger than user specified
    $intNestedESXivMemGB_toUse, $intNestedESXiCachingvDiskGB_toUse, $intNestedESXiCapacityvDiskGB_toUse = if ($DeployAsSelfManaged) {
        [Math]::Max($NestedESXivMemGB, $hshMinVESXiSizesForSelfManaged["vEsxiMemGB"]), [Math]::Max($NestedESXiCachingvDiskGB, $hshMinVESXiSizesForSelfManaged["vsanCachingVDiskGB"]), [Math]::Max($NestedESXiCapacityvDiskGB, $hshMinVESXiSizesForSelfManaged["vsanCapacityVDiskGB"])
        ## if any of the sized specified were less than the minimum vESXi resources sizes needed, write a warning
        if ($NestedESXivMemGB -lt $hshMinVESXiSizesForSelfManaged["vEsxiMemGB"] -or ($NestedESXiCachingvDiskGB -lt $hshMinVESXiSizesForSelfManaged["vsanCachingVDiskGB"]) -or ($NestedESXiCapacityvDiskGB -lt $hshMinVESXiSizesForSelfManaged["vsanCapacityVDiskGB"])) {
            Write-Warning "Specified vESXi resource size(s) were less than minimum required for 'SelfManaged' deployment; will use minimum resource sizes if continuing with deployment"
        } ## end if
    } ## end if
    ## else, Standard deploy, and just use whatever the consumer specified
    else {$NestedESXivMemGB, $NestedESXiCachingvDiskGB, $NestedESXiCapacityvDiskGB}

    Write-MyLogger "verbose logging being written to $verboseLogFile ..."
    Write-MyLogger "Connecting to $VIServer (before taking any action) ..."
    $viConnection = Connect-VIServer $VIServer -Credential $Credential -WarningAction SilentlyContinue
    $strDeploymentTargetType = if ($viConnection.ExtensionData.Content.About.ApiType -eq "VirtualCenter") {"vCenter"} else {"ESXi"}

    ## boolean:  Upgrade vESXi hosts to 6.5a? (Was path to patch's metadata.zip file specified?). Will also get set to $true if deploying NSX
    $bUpgradeESXiTo65a = $PSBoundParameters.ContainsKey("ESXi65aOfflineBundle") -and ($verVSphereVersion -eq [System.Version]"6.5")
    ## boolean:  Install NSX? (Was path to NSX OVA file specified?)
    $bDeployNSX = $PSBoundParameters.ContainsKey("NSXOVA")
    ## for when accepting $NestedESXiHostnameToIPs from pipeline (when user employed ConvertFrom-Json with a JSON cfg file), this is a PSCustomObject; need to create a hashtable from the PSCustomObject
    $hshNestedESXiHostnameToIPs = if (($NestedESXiHostnameToIPs -is [System.Collections.Hashtable]) -or ($NestedESXiHostnameToIPs -is [System.Collections.Specialized.OrderedDictionary])) {
        $NestedESXiHostnameToIPs
    } else {
        ## make a hashtable, populate key/value pairs, return hashtable
        $NestedESXiHostnameToIPs.psobject.Properties | Foreach-Object -Begin {$hshTmp = @{}} -Process {$hshTmp[$_.Name] = $_.Value} -End {$hshTmp}
    } ## end else
    ## if this is DeployAsSelfManaged, will use the first ESXi returned from the  as the "bootstrap" VMHost to which to deploy VCSA; this will have "Name" of the short name of the vESXi VM, and "Value" that is the IP for said vESXi VM
    $oNestedEsxiHostnameAndIP_dictEntry = if ($DeployAsSelfManaged) {$hshNestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Name | Select-Object -First 1}

    if ($preCheck) {
        if ($bDeployNSX) {
            ## not testing path to NSX OVA -- already validated on parameter input
            ## check that the PowerNSX PSModule is loaded
            if (-not (Get-Module -Name "PowerNSX")) {
                Write-Host -ForegroundColor Red "`nPowerNSX Module is not loaded, please install and load PowerNSX before running script ...`nexiting"
                exit
            }
            ## if this is a deploy of vSphere 6.5, and the offline update bundle path was not specified
            if (($verVSphereVersion -eq [System.Version]"6.5") -and -not $PSBoundParameters.ContainsKey("ESXi65aOfflineBundle")) {
                Throw "Problem:  Deploying of NSX is beinging attempted (as determined by parameters specified), but the ESXi 6.5a offline bundle parameter 'ESXi65aOfflineBundle' was not provided. Please provide a value for that parameter and let us try again"
            } ## end if
        } ## end if
    } ## end if

    ##### get a few items that will eventually be used for deploys; getting them ahead of confirmation so as to be able to provide a bit more information about things, like that storage resource is a datastore or datastore cluster, or that the guest VPG specified for the VMs is a standard- or distributed portgroup
    Write-MyLogger "Gathering a bit of resource info (before taking any action) ..."
    ## the VMHost that will be used as the target/destination for many operations
    $vmhost = if ($strDeploymentTargetType -eq "ESXi") {
        Get-VMHost -Server $viConnection
    } else {
        $cluster = Get-Cluster -Server $viConnection -Name $VMCluster
        $datacenter = $cluster | Get-Datacenter
        $cluster | Get-VMHost -State:Connected | Get-Random
    } ## end else

    ## get the storage resource to use (datastorecluster or datastore)
    try {
        $oDestStorageResource = Get-DatastoreCluster -Server $viConnection -Name $VMDatastore -Location ($vmhost | Get-Datacenter) -ErrorAction:Stop
    } catch {
        Write-MyLogger "Had issue getting datastore cluster named $VMDatastore. Will try as datastore ..."
        $oDestStorageResource = Get-Datastore -Server $viConnection -Name $VMDatastore -VMHost $vmhost | Select-Object -First 1
    } ## end catch
    ## is this a datastore cluster?
    $bDestStorageIsDatastoreCluster = $oDestStorageResource -is [VMware.VimAutomation.ViCore.Types.V1.DatastoreManagement.DatastoreCluster]

    ## get the virtual portgroup to which to connect new VM objects' network adapter(s)
    try {
        $network = Get-VDPortgroup -Server $viConnection -Name $VMNetwork -ErrorAction:Stop | Select -First 1
        if ($bDeployNSX) {$privateNetwork = Get-VDPortgroup -Server $viConnection -Name $PrivateVXLANVMNetwork -ErrorAction:Stop | Select-Object -First 1}
    } catch {
        Write-MyLogger "Had issue getting vPG $VMNetwork from switch as VDS. Will try as VSS ..."
        $network = Get-VirtualPortGroup -Server $viConnection -Name $VMNetwork | Select-Object -First 1
        if ($bDeployNSX) {$privateNetwork = Get-VirtualPortGroup -Server $viConnection -Name $PrivateVXLANVMNetwork | Select-Object -First 1}
    } ## end catch

    if ($confirmDeployment) {
        ## informative, volatile writing to console (utilizing a helper function for consistent format/output, vs. oodles of explicit Write-Host calls)
        Write-Host -ForegroundColor Magenta "`nPlease confirm the following configuration will be deployed:`n"

        $strSectionHeaderLine = "vGhetto vSphere Automated Lab Deployment Configuration"
        $hshMessageBodyInfo = [ordered]@{
            "Deployment Target (detected)" = $strDeploymentTargetType
            "Deployment Type" = if ($DeployAsSelfManaged) {"SelfManaged"} else {"Standard"}
            "vSphere Version (detected)" = "vSphere $verVSphereVersion"
            "Nested ESXi Image Path" = $NestedESXiApplianceOVA
            "VCSA Image Path" = $VCSAInstallerPath
        } ## end hsh
        if ($bDeployNSX) {$hshMessageBodyInfo["NSX Image Path"] = $NSXOVA}
        if ($bUpgradeESXiTo65a) {$hshMessageBodyInfo["Extracted ESXi 6.5a Offline Patch Bundle Path"] = $ESXi65aOfflineBundle}
        _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo


        $strSectionHeaderLine = if ($strDeploymentTargetType -eq "ESXi") {"Physical ESXi Deployment Target Configuration"} else {"vCenter Server Deployment Target Configuration"}
        $hshMessageBodyInfo = [ordered]@{
            $(if ($strDeploymentTargetType -eq "ESXi") {"ESXi Address"} else {"vCenter Server Address"}) = $VIServer
            "Username" = $Credential.UserName
            "VM Network" = $VMNetwork
            "VM vPG type (detected)" = if ($network -is [VMware.VimAutomation.Vds.Types.V1.VmwareVDPortgroup]) {"Distributed"} else {"Standard"}
        } ## end hsh
        if ($bDeployNSX -and $setupVXLAN) {$hshMessageBodyInfo["Private VXLAN VM Network"] = $PrivateVXLANVMNetwork}
        $hshMessageBodyInfo["VM Storage"] = $VMDatastore
        $hshMessageBodyInfo["VM Storage type (detected)"] = ("Datastore{0}" -f $(if ($bDestStorageIsDatastoreCluster) {"Cluster"}))
        if ($strDeploymentTargetType -eq "vCenter") {
            $hshMessageBodyInfo["VM Cluster"] = $VMCluster
            $hshMessageBodyInfo["VM vApp to create"] = $VAppName
        } ## end if
        _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo


        $strSectionHeaderLine = "vESXi Configuration"
        $hshMessageBodyInfo = [ordered]@{
            "Num. Nested ESXi VMs" = $hshNestedESXiHostnameToIPs.Count
            "vCPU each ESXi VM" = $NestedESXivCPU
            "vMem each ESXi VM" = "$intNestedESXivMemGB_toUse GB"
            "Caching VMDK size" = "$intNestedESXiCachingvDiskGB_toUse GB"
            "Capacity VMDK size" = "$intNestedESXiCapacityvDiskGB_toUse GB"
            $("New ESXi VM name{0}" -f $(if ($hshNestedESXiHostnameToIPs.Count -gt 1) {"s"})) = $hshNestedESXiHostnameToIPs.Keys -join ", "
            $("IP Address{0}" -f $(if ($hshNestedESXiHostnameToIPs.Count -gt 1) {"es"})) = $hshNestedESXiHostnameToIPs.Values -join ", "
            "Netmask" = $VMNetmask
            "Gateway" = $VMGateway
            "DNS" = $VMDNS.IPAddressToString -join ", "
            "NTP" = $VMNTP
            "Syslog" = $VMSyslog
            "Enable SSH" = $VMSSH
            "Create VMFS Volume" = $VMVMFS
            "Root Password" = $VMPassword
            "Update to 6.5a" = $bUpgradeESXiTo65a
        } ## end hsh
        ## if this is a SelfManaged deploy, include info about the name of the vESXi host that will be used for "bootstrapping"
        if ($DeployAsSelfManaged) {$hshMessageBodyInfo["Bootstrap ESXi Node"] = $oNestedEsxiHostnameAndIP_dictEntry.Name}
        _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo


        $strSectionHeaderLine = "VCSA Configuration"
        $hshMessageBodyInfo = [ordered]@{
            "Deployment Size" = $VCSADeploymentSize
            "SSO Domain" = $VCSASSODomainName
            "SSO Site" = $VCSASSOSiteName
            "SSO Password" = $VCSASSOPassword
            "Root Password" = $VCSARootPassword
            "Enable SSH" = $VCSASSHEnable
            "New vC VM name" = $VCSADisplayName
            "Hostname" = $VCSAHostname
            "IP Address" = $VCSAIPAddress
            "Netmask" = $VMNetmask
            "Gateway" = $VMGateway
            "DNS" = $VMDNS.IPAddressToString -join ", "
        } ## end hsh
        if ($bDeployNSX -and $setupVXLAN) {
            $hshMessageBodyInfo["VDS Name"] = $VDSName
            $hshMessageBodyInfo["VXLAN Portgroup Name"] = $VXLANDVPortgroup
            $hshMessageBodyInfo["VXLAN Subnet"] = $VXLANSubnet
            $hshMessageBodyInfo["VXLAN Netmask"] = $VXLANNetmask
        } ## end if
        _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo


        if ($bDeployNSX) {
            $strSectionHeaderLine = "NSX Configuration"
            $hshMessageBodyInfo = [ordered]@{
                "vCPU" = $NSXvCPU
                "Memory" = "$NSXvMemGB GB"
                "Hostname" = $NSXHostname
                "IP Address" = $NSXIPAddress
                "Netmask" = $NSXNetmask
                "Gateway" = $NSXGateway
                "DNS" = $VMDNS.IPAddressToString | Select-Object -First 1
                "Enable SSH" = $NSXSSHEnable
                "Enable CEIP" = $NSXCEIPEnable
                "UI Password" = $NSXUIPassword
                "CLI Password" = $NSXCLIPassword
            } ## end hsh
            _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo
        } ## end if

        ## do some math
        $esxiTotalCPU = $hshNestedESXiHostnameToIPs.Count * $NestedESXivCPU
        $esxiTotalMemory = $hshNestedESXiHostnameToIPs.Count * $intNestedESXivMemGB_toUse
        $esxiTotalStorage = ($hshNestedESXiHostnameToIPs.Count * $intNestedESXiCachingvDiskGB_toUse) + ($hshNestedESXiHostnameToIPs.count * $intNestedESXiCapacityvDiskGB_toUse)
        $vcsaTotalCPU = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.cpu
        $vcsaTotalMemory = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.mem
        $vcsaTotalStorage = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.disk

        Write-Host -ForegroundColor Yellow "`n---- Resource Requirements ----"
        Write-Host -NoNewline -ForegroundColor Green "ESXi VM CPU: "
        Write-Host -NoNewline -ForegroundColor White $esxiTotalCPU
        Write-Host -NoNewline -ForegroundColor Green ", ESXi VM Memory: "
        Write-Host -NoNewline -ForegroundColor White "$esxiTotalMemory GB"
        Write-Host -NoNewline -ForegroundColor Green ", ESXi VM Storage: "
        Write-Host -ForegroundColor White "$esxiTotalStorage GB"
        Write-Host -NoNewline -ForegroundColor Green "VCSA VM CPU: "
        Write-Host -NoNewline -ForegroundColor White $vcsaTotalCPU
        Write-Host -NoNewline -ForegroundColor Green ", VCSA VM Memory: "
        Write-Host -NoNewline -ForegroundColor White "$vcsaTotalMemory GB"
        Write-Host -NoNewline -ForegroundColor Green ", VCSA VM Storage: "
        Write-Host -ForegroundColor White "$vcsaTotalStorage GB"

        if ($bDeployNSX) {
            $nsxTotalCPU = $NSXvCPU
            $nsxTotalMemory = $NSXvMemGB
            $nsxTotalStorage = 60
            Write-Host -NoNewline -ForegroundColor Green "NSX VM CPU: "
            Write-Host -NoNewline -ForegroundColor White $nsxTotalCPU
            Write-Host -NoNewline -ForegroundColor Green ", NSX VM Memory: "
            Write-Host -NoNewline -ForegroundColor White "$nsxTotalMemory GB"
            Write-Host -NoNewline -ForegroundColor Green ", NSX VM Storage: "
            Write-Host -ForegroundColor White "$nsxTotalStorage GB"
        }

        Write-Host -ForegroundColor White "---------------------------------------------"
        Write-Host -NoNewline -ForegroundColor Green "Total CPU: "
        Write-Host -ForegroundColor White ($esxiTotalCPU + $vcsaTotalCPU + $nsxTotalCPU)
        Write-Host -NoNewline -ForegroundColor Green "Total Memory: "
        Write-Host -ForegroundColor White "$($esxiTotalMemory + $vcsaTotalMemory + $nsxTotalMemory) GB"
        Write-Host -NoNewline -ForegroundColor Green "Total Storage: "
        Write-Host -ForegroundColor White "$($esxiTotalStorage + $vcsaTotalStorage + $nsxTotalStorage) GB"

        # Grab what are the parameters and their values, for logging info
        # $hshOut = [ordered]@{}
        # Get-Variable -Name (Get-Command -Name $PSCmdlet.MyInvocation.InvocationName).Parameters.Values.Name -ErrorAction:SilentlyContinue | Foreach-Object {$hshOut[$_.Name] = $_.Value}
        # Write-MyLogger "Writing to verbose log the params passed for this run ..."
        # $hshOut | Out-File -Append -LiteralPath $verboseLogFile

        Write-Host -ForegroundColor Magenta "`nWould you like to proceed with this deployment?`n"
        $answer = Read-Host -Prompt "Do you accept (Y or N)"
        ## need just one comparison -- "-ne" is case-insensitive by default; but, for the sake of explicitness, using the "-ine" comparison operator
        if ($answer -ine "y") {
            Write-MyLogger "Disconnecting from $VIServer (no actions taken) ..."
            Disconnect-VIServer -Server $viConnection -Confirm:$false
            exit
        } ## end if
        # Clear-Host
    } ## end of Confirm Deployment section

    if ($oDestStorageResource.Type -eq "vsan") {
        Write-MyLogger "VSAN Datastore detected, enabling Fake SCSI Reservations ..."
        Get-AdvancedSetting -Entity $vmhost -Name "VSAN.FakeSCSIReservations" | Set-AdvancedSetting -Value 1 -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
    } ## end if


    if ($deployNestedESXiVMs) {
        $dteStartOnAllVM = Get-Date
        ## create, by Import-VApp, the vESXi VMs, then Set-NetworkAdapter, Set-HardDisk, update VM config (if deploy target is ESXi), then power on
        $hshNestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Name | Foreach-Object {
            $VMName = $_.Key
            $VMIPAddress = $_.Value
            $dteStartThisVM = Get-Date
            Write-MyLogger "Deploying Nested ESXi VM $VMName ..."

            ## hashtable to use for parameter splatting so that we can conditional build the params, and then have a single workflow (one invocation spot for Import-VApp)
            $hshParamsForImportVApp = @{
                Name = $VMName
                Server = $viConnection
                Source = $NestedESXiApplianceOVA
                VMHost = $vmhost
                Datastore = $oDestStorageResource
                DiskStorageFormat = "Thin"
            } ## end hsh

            ## if deploying to and ESXi host, need to use ExtraConfig items for the new VM (cannot use the OvfConfiguration parameter to Import-VApp)
            if ($strDeploymentTargetType -eq "ESXi") {
                ## make a hashtable of items to add to new VM as ExtraConfig
                $hshNewExtraConfigKeysAndValues = @{
                    "guestinfo.hostname" = $VMName
                    "guestinfo.ipaddress" = $VMIPAddress
                    "guestinfo.netmask" = $VMNetmask.IPAddressToString
                    "guestinfo.gateway" = $VMGateway.IPAddressToString
                    "guestinfo.dns" = $VMDNS.IPAddressToString | Select-Object -First 1
                    "guestinfo.domain" = $VMDomain
                    "guestinfo.ntp" = $VMNTP
                    "guestinfo.syslog" = $VMSyslog
                    "guestinfo.password" = $VMPassword
                    "guestinfo.ssh" = $VMSSH.ToString()
                    "guestinfo.createvmfs" = $VMVMFS.ToString()
                } ## end hsh
            } ## end if
            ## else, deploying to a vCenter -- can use the OvfConfiguration parameter to Import-VApp
            else {
                ## set the OVF Config values, to be used during Import-VApp
                $ovfconfig = Get-OvfConfiguration $NestedESXiApplianceOVA
                $ovfconfig.NetworkMapping.VM_Network.value = $VMNetwork
                $ovfconfig.common.guestinfo.hostname.value = $VMName
                $ovfconfig.common.guestinfo.ipaddress.value = $VMIPAddress
                $ovfconfig.common.guestinfo.netmask.value = $VMNetmask.IPAddressToString
                $ovfconfig.common.guestinfo.gateway.value = $VMGateway.IPAddressToString
                $ovfconfig.common.guestinfo.dns.value = $VMDNS.IPAddressToString | Select-Object -First 1
                $ovfconfig.common.guestinfo.domain.value = $VMDomain
                $ovfconfig.common.guestinfo.ntp.value = $VMNTP
                $ovfconfig.common.guestinfo.syslog.value = $VMSyslog
                $ovfconfig.common.guestinfo.password.value = $VMPassword
                $ovfconfig.common.guestinfo.ssh.value = $VMSSH.ToString()
                $ovfconfig.common.guestinfo.createvmfs.value = $VMVMFS.ToString()

                $hshParamsForImportVApp["OvfConfiguration"] = $ovfconfig
            } ## end else

            ## do the actual vApp import
            $vm = Import-VApp @hshParamsForImportVApp

            # Add the dvfilter settings to the exisiting ethernet1 (not part of ova template)
            Write-MyLogger "Setting needed dvFilter settings for Eth1 ..."
            $vm | New-AdvancedSetting -Name "ethernet1.filter4.name" -Value "dvfilter-maclearn" -Confirm:$false -Type VM | Out-File -Append -LiteralPath $verboseLogFile
            $vm | New-AdvancedSetting -Name "ethernet1.filter4.onFailure" -Value "failOpen" -Confirm:$false -Type VM | Out-File -Append -LiteralPath $verboseLogFile

            ## if this is to an ESXi host, need to set first NetworkAdapter's portgroup here (when deploying to vCenter, not necessary, as NetworkAdapters' PortGroup set via OVF config)
            if ($strDeploymentTargetType -eq "ESXi") {
                Write-MyLogger "Updating VM Network ..."
                $vm | Get-NetworkAdapter -Name "Network adapter 1" | Set-NetworkAdapter -Portgroup $network -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                Start-Sleep -Seconds 5
            } ## end if

            ## determine which portgroup to use for second network adapter, then just have one call to Set-NetworkAdapter
            $oPortgroupForSecondNetAdapter = if ($bDeployNSX) {$privateNetwork} else {$network}
            Write-MyLogger "Connecting Eth1 to $oPortgroupForSecondNetAdapter ..."
            $vm | Get-NetworkAdapter -Name "Network adapter 2" | Set-NetworkAdapter -Portgroup $oPortgroupForSecondNetAdapter -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            Write-MyLogger "Updating vCPU Count to $NestedESXivCPU & vMem to $intNestedESXivMemGB_toUse GB ..."
            Set-VM -Server $viConnection -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $intNestedESXivMemGB_toUse -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            Write-MyLogger "Updating vSAN Caching VMDK size to $intNestedESXiCachingvDiskGB_toUse GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $intNestedESXiCachingvDiskGB_toUse -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            Write-MyLogger "Updating vSAN Capacity VMDK size to $intNestedESXiCapacityvDiskGB_toUse GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $intNestedESXiCapacityvDiskGB_toUse -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            if ($strDeploymentTargetType -eq "ESXi") {
                ## make a new VMConfigSpec with which to reconfigure this VM
                $spec = New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{
                    ## make a new ExtraConfig object that is the concatenation of the original ExtraConfig and an array of new OptionValue objects created from the key/value pairs of the given hashtable
                    ExtraConfig = $vm.ExtensionData.Config.ExtraConfig + @(
                        $hshNewExtraConfigKeysAndValues.Keys | Foreach-Object {New-Object -Type VMware.Vim.OptionValue -Property @{Key = $_; Value = $hshNewExtraConfigKeysAndValues[$_]}}
                    ) ## end of ExtraConfig array of config OptionValue objects
                } ## end new-object

                Write-MyLogger "Adding guestinfo customization properties to $VMName by reconfiguring the VM ..."
                $task = $vm.ExtensionData.ReconfigVM_Task($spec)
                Get-Task -Id $task | Wait-Task | Out-Null
            } ## end if
            else {Write-MyLogger "No additional guestinfo customization properties to set on $VMName, continuing ..."}

            Write-MyLogger "Powering On $VMName ..."
            Start-VM -Server $viConnection -VM $vm -RunAsync -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            Write-MyLogger ("Timespan for VM ${VMName}: {0}" -f ((Get-Date) - $dteStartThisVM))
        } ## end foreach-object
        Write-MyLogger ("Timespan for all vESXi VMs: {0}" -f ((Get-Date) - $dteStartOnAllVM))
    } ## end deployNestedESXiVMs


    if ($bDeployNSX) {
        if ($strDeploymentTargetType -eq "vCenter") {
            $dteStartThisVM = Get-Date
            $ovfconfig = Get-OvfConfiguration $NSXOVA
            $ovfconfig.NetworkMapping.VSMgmt.value = $VMNetwork

            $ovfconfig.common.vsm_hostname.value = $NSXHostname
            $ovfconfig.common.vsm_ip_0.value = $NSXIPAddress.IPAddressToString
            $ovfconfig.common.vsm_netmask_0.value = $NSXNetmask.IPAddressToString
            $ovfconfig.common.vsm_gateway_0.value = $NSXGateway.IPAddressToString
            ## per the comments in the OVF config:  "The DNS server list(comma separated) for this VM."
            $ovfconfig.common.vsm_dns1_0.value = $VMDNS.IPAddressToString -join ","
            $ovfconfig.common.vsm_domain_0.value = $VMDomain
            $ovfconfig.common.vsm_isSSHEnabled.value = $NSXSSHEnable.ToString()
            $ovfconfig.common.vsm_isCEIPEnabled.value = $NSXCEIPEnable.ToString()
            $ovfconfig.common.vsm_cli_passwd_0.value = $NSXUIPassword
            $ovfconfig.common.vsm_cli_en_passwd_0.value = $NSXCLIPassword

            Write-MyLogger "Deploying NSX VM $NSXDisplayName ..."
            $vm = Import-VApp -Source $NSXOVA -OvfConfiguration $ovfconfig -Name $NSXDisplayName -Location $cluster -VMHost $vmhost -Datastore $oDestStorageResource -DiskStorageFormat thin

            Write-MyLogger "Updating vCPU Count to $NSXvCPU & vMem to $NSXvMemGB GB ..."
            Set-VM -Server $viConnection -VM $vm -NumCpu $NSXvCPU -MemoryGB $NSXvMemGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            Write-MyLogger "Powering On $NSXDisplayName ..."
            $vm | Start-Vm -RunAsync | Out-Null
            Write-MyLogger ("Timespan for deploying NSX Manager appliance: {0}" -f ((Get-Date) - $dteStartThisVM))
        } ## end if
        else {Write-MyLogger "Not deploying NSX -- connected to an ESXi host ..."}
    } ## end of deploying NSX


    if ($bUpgradeESXiTo65a) {
        $hshNestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Name | Foreach-Object {
            $dteStartThisVM = Get-Date
            $VMName = $_.Key
            $VMIPAddress = $_.Value

            Write-MyLogger "Connecting directly to $VMName for ESXi upgrade ..."
            $vESXi = Connect-VIServer -Server $VMIPAddress -User root -Password $VMPassword -WarningAction SilentlyContinue

            Write-MyLogger "Entering Maintenance Mode ..."
            Set-VMHost -VMhost $VMIPAddress -State Maintenance -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            Write-MyLogger "Upgrading $VMName to ESXi 6.5a ..."
            Install-VMHostPatch -VMHost $VMIPAddress -LocalPath $ESXi65aOfflineBundle -HostUsername root -HostPassword $VMPassword -WarningAction SilentlyContinue -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            Write-MyLogger "Rebooting $VMName ..."
            Restart-VMHost $VMIPAddress -RunAsync -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            Write-MyLogger "Disconnecting from new ESXi host ..."
            Disconnect-VIServer $vESXi -Confirm:$false
            Write-MyLogger ("Timespan for patching VMHost ${VMName}: {0}" -f ((Get-Date) - $dteStartThisVM))
        }
    } ## end of upgrading ESXi to 6.5a


    ## "bootstrap" the first new ESXi VM if this is a SelfManaged deploy
    if ($bootStrapFirstNestedESXiVM -and $DeployAsSelfManaged) {
        $strNameOfBootstrapVESXi = $oNestedEsxiHostnameAndIP_dictEntry.Name
        $strIPOfBootstrapVESXi = $oNestedEsxiHostnameAndIP_dictEntry.Value
        Write-MyLogger "Starting 'bootstrap' activities on vESXi '$strNameOfBootstrapVESXi' ..."
        ## wait until given vESXi host is at least responsive to ping requests
        do {
            Write-MyLogger "Waiting for $strNameOfBootstrapVESXi to be responsive on network ..."
            $bBootstrapNodeResponsiveToPingRequest = Test-Connection -ComputerName $strIPOfBootstrapVESXi -Quiet
            if (-not $bBootstrapNodeResponsiveToPingRequest) {Start-Sleep -Seconds 60}
        } until ($bBootstrapNodeResponsiveToPingRequest)

        Write-MyLogger "Connecting to vESXi bootstrap node to prepare VSAN ..."
        $vEsxiVIConnection = Connect-VIServer -Server $strIPOfBootstrapVESXi -User root -Password $VMPassword -WarningAction SilentlyContinue

        Write-MyLogger "Updating the vESXi host VSAN Policy to allow Force Provisioning (temporarily) ..."
        $esxcli = Get-EsxCli -Server $vEsxiVIConnection -V2
        $VSANPolicy = '(("hostFailuresToTolerate" i1) ("forceProvisioning" i1))'
        $VSANPolicyDefaults = $esxcli.vsan.policy.setdefault.CreateArgs()
        $VSANPolicyDefaults.policy = $VSANPolicy
        $VSANPolicyDefaults.policyclass = "vdisk"
        $esxcli.vsan.policy.setdefault.Invoke($VSANPolicyDefaults) | Out-File -Append -LiteralPath $verboseLogFile
        $VSANPolicyDefaults.policyclass = "vmnamespace"
        $esxcli.vsan.policy.setdefault.Invoke($VSANPolicyDefaults) | Out-File -Append -LiteralPath $verboseLogFile

        Write-MyLogger "Creating a new VSAN Cluster"
        $esxcli.vsan.cluster.new.Invoke() | Out-File -Append -LiteralPath $verboseLogFile

        Write-MyLogger "Querying ESXi host disks to create VSAN Diskgroups ..."
        $luns = Get-ScsiLun -Server $vEsxiVIConnection | Select-Object CanonicalName, CapacityGB
        $vsanCacheDisk = ($luns | Where-Object {$_.CapacityGB -eq $intNestedESXiCachingvDiskGB_toUse} | Get-Random).CanonicalName
        $vsanCapacityDisk = ($luns | Where-Object {$_.CapacityGB -eq $intNestedESXiCapacityvDiskGB_toUse} | Get-Random).CanonicalName

        Write-MyLogger "Tagging VSAN Capacity Disk ..."
        $capacitytag = $esxcli.vsan.storage.tag.add.CreateArgs()
        $capacitytag.disk = $vsanCapacityDisk
        $capacitytag.tag = "capacityFlash"
        $esxcli.vsan.storage.tag.add.Invoke($capacitytag) | Out-File -Append -LiteralPath $verboseLogFile

        Write-MyLogger "Creating VSAN Diskgroup ..."
        $addvsanstorage = $esxcli.vsan.storage.add.CreateArgs()
        $addvsanstorage.ssd = $vsanCacheDisk
        $addvsanstorage.disks = $vsanCapacityDisk
        $esxcli.vsan.storage.add.Invoke($addvsanstorage) | Out-File -Append -LiteralPath $verboseLogFile

        Write-MyLogger "Disconnecting from $strNameOfBootstrapVESXi ..."
        Disconnect-VIServer $vEsxiVIConnection -Confirm:$false
    } ## end of bootstrapping first ESXi VM


    if ($deployVCSA) {
        $dteStartThisVCSA = Get-Date
        ## the filespec to use for the temporary config json file that will be created, used for VCSA deploy, and then removed
        $strTmpConfigJsonFilespec = "${ENV:Temp}\jsontemplate_${random_string}.json"

        ## the name of the key (specific to the deployment target type of ESXi or vCenter), and the name of the JSON file that has the respective VCSA config
        $strKeynameForOvfConfig_DeplTarget, $strCfgJsonFilename = if (($strDeploymentTargetType -eq "ESXi") -or $DeployAsSelfManaged) {
            $(if ($verVSphereVersion -lt [System.Version]"6.5") {"esx"} else {"esxi"}), "embedded_vCSA_on_ESXi.json"
        } else {"vc", "embedded_vCSA_on_VC.json"}
        ## "strKeynameForOvfConfig_VCSAPortion":  the first subkey in the config is "target.vcsa" in 6.0, and "new.vcsa" in 6.5
        ## "strKeynameForOvfConfig_SysnamePortion":  the name of the subkey that is used for the system hostname -- "hostname" in 6.0, and "system.name" in 6.5
        $strKeynameForOvfConfig_VCSAPortion, $strKeynameForOvfConfig_SysnamePortion = if ($verVSphereVersion -lt [System.Version]"6.5") {"target.vcsa", "hostname"} else {"new.vcsa", "system.name"}

        if (-not $DeployAsSelfManaged) {
            ## as of now, the VCSA CLI installer seems to not support deploying to datastore cluster; so, if the storage resource specified by the user was a datastore cluster, will use, for the VCSA deploy, the datastore with the most freespace that is in the datastorecluster
            $strNameOfDestDatastoreForVCSA = if ($bDestStorageIsDatastoreCluster) {
                $oDStoreWithMostFreespaceInThisDSCluster = $oDestStorageResource | Get-Datastore -Refresh | Sort-Object FreeSpaceGB -Descending:$true | Select-Object -First 1
                Write-MyLogger "Storage resource specified is a datastorecluster, but VCSA deployment tool desires a datastore, so selected datastore '$oDStoreWithMostFreespaceInThisDSCluster' from datastorecluster '$oDestStorageResource'"
                $oDStoreWithMostFreespaceInThisDSCluster.Name
            } else {$oDestStorageResource.Name}
        } ## end if

        ## if DeployAsSelfManaged, need to specify the vESXi-specific values for hostname, username, password, 'deployment.network', and datastore
        $strForCfg_hostname, $strForCfg_username, $strForCfg_password, $strForCfg_deploymentNetwork, $strForCfg_datastore = if ($DeployAsSelfManaged) {
            ## vESXi IP, root, the password on the new vESXi host, the default "VM Network" vPG, and the default VSAN datastore name
            $oNestedEsxiHostnameAndIP_dictEntry.Value, "root", $VMPassword, "VM Network", "vsanDatastore"
        } ## if if
        ## else, will use the VIServer, the creds and VMNetwork passed in, and the appropriate destination datastore
        else {$VIServer, $Credential.UserName, $Credential.GetNetworkCredential().Password, $VMNetwork, $strNameOfDestDatastoreForVCSA}

        # Deploy using the VCSA CLI Installer
        $config = (Get-Content -Raw "${VCSAInstallerPath}\vcsa-cli-installer\templates\install\${strCfgJsonFilename}") | ConvertFrom-Json
        ## these with "$strKeynameForOvfConfig_DeplTarget" in the path are used for both deployment types, but have one different key in them
        $config.$strKeynameForOvfConfig_VCSAPortion.$strKeynameForOvfConfig_DeplTarget.hostname = $strForCfg_hostname
        $config.$strKeynameForOvfConfig_VCSAPortion.$strKeynameForOvfConfig_DeplTarget.username = $strForCfg_username
        $config.$strKeynameForOvfConfig_VCSAPortion.$strKeynameForOvfConfig_DeplTarget.password = $strForCfg_password
        ## the parent key of the "deployment.network" subkey name differs between 6.0 and 6.5:  it is "appliance" in 6.0, $strKeynameForOvfConfig_DeplTarget in 6.5 (either "esxi" or "vc")
        $strKeynameForDeplNetworkParentKey = if ($verVSphereVersion -lt [System.Version]"6.5") {"appliance"} else {$strKeynameForOvfConfig_DeplTarget}
        $config.$strKeynameForOvfConfig_VCSAPortion.$strKeynameForDeplNetworkParentKey.'deployment.network' = $strForCfg_deploymentNetwork
        $config.$strKeynameForOvfConfig_VCSAPortion.$strKeynameForOvfConfig_DeplTarget.datastore = $strForCfg_datastore
        ## only add these two config items if the deployment target is vCenter
        if ($strDeploymentTargetType -eq "vCenter" -and (-not $DeployAsSelfManaged)) {
            $config.$strKeynameForOvfConfig_VCSAPortion.$strKeynameForOvfConfig_DeplTarget.datacenter = $datacenter.name
            $config.$strKeynameForOvfConfig_VCSAPortion.$strKeynameForOvfConfig_DeplTarget.target = $VMCluster
        } ## end
        $config.$strKeynameForOvfConfig_VCSAPortion.appliance.'thin.disk.mode' = $true
        $config.$strKeynameForOvfConfig_VCSAPortion.appliance.'deployment.option' = $VCSADeploymentSize.ToLower()
        $config.$strKeynameForOvfConfig_VCSAPortion.appliance.name = $VCSADisplayName
        $config.$strKeynameForOvfConfig_VCSAPortion.network.'ip.family' = "ipv4"
        $config.$strKeynameForOvfConfig_VCSAPortion.network.mode = "static"
        $config.$strKeynameForOvfConfig_VCSAPortion.network.ip = $VCSAIPAddress.IPAddressToString
        $config.$strKeynameForOvfConfig_VCSAPortion.network.'dns.servers' = $VMDNS | Foreach-Object {$_.IPAddressToString}
        $config.$strKeynameForOvfConfig_VCSAPortion.network.prefix = $VCSAPrefix.ToString()
        $config.$strKeynameForOvfConfig_VCSAPortion.network.gateway = $VMGateway.IPAddressToString
        $config.$strKeynameForOvfConfig_VCSAPortion.network.$strKeynameForOvfConfig_SysnamePortion = $VCSAHostname
        $config.$strKeynameForOvfConfig_VCSAPortion.os.password = $VCSARootPassword
        $config.$strKeynameForOvfConfig_VCSAPortion.os.'ssh.enable' = $VCSASSHEnable.ToBool()
        $config.$strKeynameForOvfConfig_VCSAPortion.sso.password = $VCSASSOPassword
        $config.$strKeynameForOvfConfig_VCSAPortion.sso.'domain-name' = $VCSASSODomainName
        $config.$strKeynameForOvfConfig_VCSAPortion.sso.'site-name' = $VCSASSOSiteName

        Write-MyLogger "Creating VCSA JSON Configuration file for deployment ..."
        $config | ConvertTo-Json -Depth 3 | Set-Content -Path $strTmpConfigJsonFilespec

        ## only use the CEIP param if 6.5 or up (6.0 does not have this option)
        $strAckCeip = if ($verVSphereVersion -ge [System.Version]"6.5") {"--acknowledge-ceip"}
        Write-MyLogger "Deploying the VCSA ..."
        ## btw, for troubleshooting vcsa-deploy.exe situations, "--verify-only" parameter is handy for things like .json template validation, deployment attempt validation
        Invoke-Command -ScriptBlock {& "${VCSAInstallerPath}\vcsa-cli-installer\win32\vcsa-deploy.exe" install --no-esx-ssl-verify --accept-eula $strAckCeip $strTmpConfigJsonFilespec} -ErrorVariable vcsaDeployErrorOutput *>&1 | Out-File -Append -LiteralPath $verboseLogFile
        ## also put the "ErrorVariable" output in the log file -- the vcsa-deploy from v6.0 writes to that ErrorVariable, not to the console host
        $vcsaDeployErrorOutput | Out-File -Append -LiteralPath $verboseLogFile
        ## teeing object so that, while all actions get written to verbose log, we can display the OVF Tool disk progress
        # Invoke-Command -ScriptBlock {& "${VCSAInstallerPath}\vcsa-cli-installer\win32\vcsa-deploy.exe" install --no-esx-ssl-verify --accept-eula --acknowledge-ceip $strTmpConfigJsonFilespec} | Tee-Object -Append -FilePath $verboseLogFile | Select-String "disk progress"
        Write-MyLogger "done with VCSA deploy action, removing temporary configuration JSON file '$strTmpConfigJsonFilespec' ..."
        if (Test-Path -Path $strTmpConfigJsonFilespec) {Remove-Item -Force -Path $strTmpConfigJsonFilespec}
        Write-MyLogger ("Timespan for deploying VCSA ${VCSADisplayName}: {0}" -f ((Get-Date) - $dteStartThisVCSA))
    } ## end if deployVCSA


    if ($moveVMsIntovApp -and ($strDeploymentTargetType -eq "vCenter")) {
        Write-MyLogger "Creating vApp $VAppName ..."
        $VApp = New-VApp -Name $VAppName -Server $viConnection -Location $cluster

        if ($deployNestedESXiVMs) {
            Write-MyLogger "Moving Nested ESXi VMs into vApp $VAppName ..."
            Get-VM -Name ($hshNestedESXiHostnameToIPs.Keys | Foreach-Object {$_}) -Server $viConnection | Move-VM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        } ## end if

        if ($deployVCSA -and (-not $DeployAsSelfManaged)) {
            Write-MyLogger "Moving $VCSADisplayName into vApp $VAppName ..."
            Get-VM -Name $VCSADisplayName -Server $viConnection | Move-VM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        } ## end if

        if ($bDeployNSX) {
            Write-MyLogger "Moving $NSXDisplayName into vApp $VAppName ..."
            Get-VM -Name $NSXDisplayName -Server $viConnection | Move-VM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        } ## end if
    } ## end if
    else {Write-MyLogger "Not creating vApp $VAppName"}

    Write-MyLogger "Disconnecting from $VIServer ..."
    Disconnect-VIServer $viConnection -Confirm:$false


    if ($setupNewVC) {
        Write-MyLogger "Connecting to the new VCSA ..."
        $vc = Connect-VIServer $VCSAIPAddress.IPAddressToString -User "administrator@$VCSASSODomainName" -Password $VCSASSOPassword -WarningAction SilentlyContinue

        Write-MyLogger "Creating Datacenter $NewVCDatacenterName ..."
        New-Datacenter -Server $vc -Name $NewVCDatacenterName -Location (Get-Folder -Type Datacenter -Server $vc) | Out-File -Append -LiteralPath $verboseLogFile

        Write-MyLogger "Creating VSAN-enabled cluster $NewVCVSANClusterName ..."
        New-Cluster -Server $vc -Name $NewVCVSANClusterName -Location (Get-Datacenter -Name $NewVCDatacenterName -Server $vc) -DrsEnabled -VsanEnabled -VsanDiskClaimMode 'Manual' | Out-File -Append -LiteralPath $verboseLogFile

        if ($addESXiHostsToVC) {
            $hshNestedESXiHostnameToIPs.GetEnumerator() | sort -Property Value | Foreach-Object {
                $VMName = $_.Key
                $VMIPAddress = $_.Value

                $targetVMHost = if ($AddHostByDnsName) {$VMName} else {$VMIPAddress}

                Write-MyLogger "Adding ESXi host $targetVMHost to Cluster $NewVCVSANClusterName ..."
                Add-VMHost -Server $vc -Location (Get-Cluster -Name $NewVCVSANClusterName) -User "root" -Password $VMPassword -Name $targetVMHost -Force | Out-File -Append -LiteralPath $verboseLogFile
            } ## end foreach-object
        } ## end if addESXiHostsToVC

        if ($bDeployNSX -and $setupVXLAN) {
            Write-MyLogger "Creating VDS $VDSName ..."
            $vds = New-VDSwitch -Server $vc -Name $VDSName -Location (Get-Datacenter -Name $NewVCDatacenterName)

            Write-MyLogger "Creating new VXLAN DVPortgroup $VXLANDVPortgroup ..."
            $vxlanDVPG = New-VDPortgroup -Server $vc -Name $VXLANDVPortgroup -Vds $vds

            Get-Cluster -Server $vc -Name $NewVCVSANClusterName | Get-VMHost | Foreach-Object {
                $oThisVMHost = $_
                Write-MyLogger "Adding $($oThisVMHost.name) to VDS ..."
                Add-VDSwitchVMHost -Server $vc -VDSwitch $vds -VMHost $oThisVMHost | Out-File -Append -LiteralPath $verboseLogFile

                Write-MyLogger "Adding vmmnic1 to VDS ..."
                $vmnic = $oThisVMHost | Get-VMHostNetworkAdapter -Physical -Name vmnic1
                Add-VDSwitchPhysicalNetworkAdapter -Server $vc -DistributedSwitch $vds -VMHostPhysicalNic $vmnic -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                $vmk0 = Get-VMHostNetworkAdapter -Server $vc -Name vmk0 -VMHost $oThisVMHost
                $lastNetworkOcet = $vmk0.ip.Split('.')[-1]
                ## make the new VMKernel portgroup IP from the first three octects of the given Subnet address and the last octet of this VMHost's management IP address
                $vxlanVmkIP = ($VXLANSubnet.IPAddressToString.Split(".")[0..2],$lastNetworkOcet | Foreach-Object {$_}) -join "."

                Write-MyLogger "Adding VXLAN VMKernel $vxlanVmkIP to VDS ..."
                New-VMHostNetworkAdapter -VMHost $oThisVMHost -PortGroup $VXLANDVPortgroup -VirtualSwitch $vds -IP $vxlanVmkIP -SubnetMask $VXLANNetmask.IPAddressToString -Mtu 1600 | Out-File -Append -LiteralPath $verboseLogFile
            } ## end foreach-object
        } ## end bDeployNSX and setupVXLAN

        if ($configureVSANDiskGroups) {
            $dteStartThisSection = Get-Date

            $VmhostToCheckVersion = Get-Cluster -Name $NewVCVSANClusterName -Server $vc | Get-VMHost | Select-Object -First 1
            $verMajorVersion = [System.Version]$VmhostToCheckVersion.Version
            $intUpdateVersion = [int](Get-AdvancedSetting -Entity $VmhostToCheckVersion -Name Misc.HostAgentUpdateLevel).value
            # vSAN cmdlets only work on v6.0u3 and up, and v6.5 and up
            if (($verMajorVersion -ge [System.Version]"6.5.0") -or ($verMajorVersion -eq [System.Version]"6.0.0" -and $intUpdateVersion -ge 3)) {
                Write-MyLogger "Enabling VSAN Space Efficiency/De-Dupe & disabling VSAN Health Check on cluster $NewVCVSANClusterName ..."
                Get-VsanClusterConfiguration -Server $vc -Cluster $NewVCVSANClusterName | Set-VsanClusterConfiguration -SpaceEfficiencyEnabled $true -HealthCheckIntervalMinutes 0 | Out-File -Append -LiteralPath $verboseLogFile
            } ## end if
            else {Write-MyLogger "Not tweaking VSAN settings -- VSAN cmdlets do not support this vSphere version ($verMajorVersion, update $intUpdateVersion) ..."}

            ## create the new VSAN disk groups, but in parallel (running asynchronously); will wait for the tasks to complete in next step
            $arrTasksForNewVSanDiskGroup = Get-Cluster -Name $NewVCVSANClusterName -Server $vc | Get-VMHost | Foreach-Object {
                $oThisVMHost = $_
                ## if this host does not already have a VSAN disk group, make one (instance in which VMHost may already have one:  this is a "self-managed" deployment, and this VMHost is the "bootstrap" host for which the VSAN diskgroup was already credated)
                if ($null -eq (Get-VsanDiskGroup -VMHost $oThisVMHost)) {
                    Write-MyLogger "Querying disks on ESXi host $($oThisVMHost.Name) to create VSAN Diskgroups ..."
                    $luns = $oThisVMHost | Get-ScsiLun | Select-Object CanonicalName, CapacityGB
                    $vsanCacheDisk = ($luns | Where-Object {$_.CapacityGB -eq $intNestedESXiCachingvDiskGB_toUse} | Get-Random).CanonicalName
                    $vsanCapacityDisk = ($luns | Where-Object {$_.CapacityGB -eq $intNestedESXiCapacityvDiskGB_toUse} | Get-Random).CanonicalName

                    Write-MyLogger "Creating VSAN DiskGroup for $oThisVMHost (asynchronously) ..."
                    New-VsanDiskGroup -Server $vc -VMHost $oThisVMHost -SsdCanonicalName $vsanCacheDisk -DataDiskCanonicalName $vsanCapacityDisk -RunAsync
                } ## end if
                else {Write-MyLogger "ESXi host $($oThisVMHost.Name) already has VSAN Diskgroup; continuing ..."}
            } ## end foreach-object

            ## then, wait for the tasks to finish, and return the resulting objects to the verbose log file
            Write-MyLogger ("Waiting for VSAN DiskGroup creation to finish for {0} host{1} ..." -f $arrTasksForNewVSanDiskGroup.Count, $(if ($arrTasksForNewVSanDiskGroup.Count -ne 1) {"s"}))
            Wait-Task -Task $arrTasksForNewVSanDiskGroup | Out-File -Append -LiteralPath $verboseLogFile
            Write-MyLogger ("Timespan for configuring VSAN items: {0}" -f ((Get-Date) - $dteStartThisSection))
        } ## end configureVSANDiskGroups

        if ($clearVSANHealthCheckAlarm) {
            Write-MyLogger "Clearing default VSAN Health Check Alarms (they're not applicable in Nested ESXi env) ..."
            $alarmMgr = Get-View AlarmManager -Server $vc
            Get-Cluster -Name $NewVCVSANClusterName -Server $vc | Where-Object {$_.ExtensionData.TriggeredAlarmState} | Foreach-Object {
                $cluster = $_
                $Cluster.ExtensionData.TriggeredAlarmState | Foreach-Object {$alarmMgr.AcknowledgeAlarm($_.Alarm,$cluster.ExtensionData.MoRef)}
            } ## end foreach-object
        } ## end if

        # Exit maintanence mode in case patching was done earlier
        Get-Cluster -Name $NewVCVSANClusterName -Server $vc | Get-VMHost -State:Maintenance | Set-VMHost -State Connected -RunAsync -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

        ## if this was deployed as self-manged, need to set the VSAN policy back to defaults (was temporarily set to enable force-provisioning)
        if ($DeployAsSelfManaged) {
            Write-MyLogger "Updating VSAN Default VM Storage Policy back to its defaults ..."
            $VSANPolicy = Get-SpbmStoragePolicy -Server $vc -Name "Virtual SAN Default Storage Policy"
            $Ruleset = New-SpbmRuleSet -Name "Rule-set 1" -AllOfRules @((New-SpbmRule -Capability VSAN.forceProvisioning $false), (New-SpbmRule -Capability VSAN.hostFailuresToTolerate 1))
            $VSANPolicy | Set-SpbmStoragePolicy -RuleSet $Ruleset | Out-File -Append -LiteralPath $verboseLogFile
        } ## end if

        Write-MyLogger "Disconnecting from new VCSA ..."
        Disconnect-VIServer $vc -Confirm:$false
    } ## end setupNewVC


    if ($configureNSX -and $bDeployNSX -and $setupVXLAN) {
        if (!(Connect-NSXServer -Server $NSXHostname -Username admin -Password $NSXUIPassword -DisableVIAutoConnect -WarningAction SilentlyContinue)) {
            Write-Host -ForegroundColor Red "Unable to connect to NSX Manager, please check the deployment"
            exit
        } else {Write-MyLogger "Successfully logged into NSX Manager $NSXHostname ..."}

        $ssoUsername = "administrator@$VCSASSODomainName"
        Write-MyLogger "Registering NSX Manager with vCenter Server $VCSAHostname ..."
        $vcConfig = Set-NsxManager -vCenterServer $VCSAHostname -vCenterUserName $ssoUsername -vCenterPassword $VCSASSOPassword

        Write-MyLogger "Registering NSX Manager with vCenter SSO $VCSAHostname ..."
        $ssoConfig = Set-NsxManager -SsoServer $VCSAHostname -SsoUserName $ssoUsername -SsoPassword $VCSASSOPassword -AcceptAnyThumbprint

        Write-MyLogger "Disconnecting from NSX Manager ..."
        Disconnect-NsxServer
    }

    $EndTime = Get-Date
    $duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

    Write-MyLogger "vSphere $verVSphereVersion Lab Deployment Complete!"
    Write-MyLogger "StartTime:  $($StartTime.ToString($strLoggingDatetimeFormatString))"
    Write-MyLogger "  EndTime:  $($EndTime.ToString($strLoggingDatetimeFormatString))"
    Write-MyLogger " Duration:  $duration minutes"
} ## end process