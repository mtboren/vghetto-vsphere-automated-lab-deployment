<#  .Description
    PowerCLI script to deploy a fully functional vSphere 6.5 lab consisting of 3
      Nested ESXi hosts enable w/vSAN + VCSA 6.5. Expects a single physical ESXi host
      as the endpoint and all four VMs will be deployed to physical ESXi host

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

    ## Full path to the OVA of the Nested ESXi 6.5 virtual appliance. Example: "C:\temp\Nested_ESXi6.5_Appliance_Template_v1.ova"
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -Path $_})][string]$NestedESXiApplianceOVA,
    ## Full Path to where the contents of the VCSA 6.5 ISO can be accessed. Say, either a folder into which the ISO was extracted, or a drive letter as which the ISO is mounted. For example, "C:\Temp\VMware-VCSA-all-6.5.0-4944578" or "D:\"
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

    ## VCSA Deployment Configuration -- the "size" setting to use for determining the number of CPU and the amount of memory/disk for the new VCSA VM. Defaults to "Tiny".  Some sizing info:  the vCPU values used for these sizes, respectively, are 2, 4, 8, 16, and 24
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
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- datastore on which to create new VMs
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][string]$VMDatastore = "himalaya-local-SATA-dc3500-0",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- subnet mask to use in Guest OS networking configuration
    [parameter(ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VMNetmask = "255.255.255.0",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- default gateway to use in Guest OS networking configuration
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VMGateway = "172.30.0.1",
    ## General Deployment Configuration for both the Nested ESXi VMs and the VCSA -- IP of DNS server to use in Guest OS networking configuration (only support for specifying single DNS server for now)
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][System.Net.IPAddress]$VMDNS,
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
    $verboseLogFile = "vsphere65-vghetto-lab-deployment.log"
    $vSphereVersion = "6.5"
    $deploymentType = "Standard"
    ## create an eight-character string from lower- and upper alpha characters, for use in creating unique vApp name
    $random_string = -join ([char]"a"..[char]"z" + [char]"A"..[char]"Z" | Get-Random -Count 8 | Foreach-Object {[char]$_})
    $VAppName = "vGhetto-Nested-vSphere-Lab-$vSphereVersion-$random_string"

    ## hashtable for VCSA "size" name to resource sizing correlation
    $vcsaSize2MemoryStorageMap = @{
        tiny   = @{cpu = 2;  mem = 10; disk = 250}
        small  = @{cpu = 4;  mem = 16; disk = 290}
        medium = @{cpu = 8;  mem = 24; disk = 425}
        large  = @{cpu = 16; mem = 32; disk = 640}
        xlarge = @{cpu = 24; mem = 48; disk = 980}
    } ## end config hashtable

    ## import these modules if not already imported in this PowerShell session
    "VMware.VimAutomation.Core", "VMware.VimAutomation.Vds", "VMware.VimAutomation.Storage" | Foreach-Object {if (-not (Get-Module -Name $_ -ErrorAction:SilentlyContinue)) {Import-Module -Name $_}}

    Function My-Logger {
        param (
            [Parameter(Mandatory=$true)][String]$Message
        ) ## end param

        $timeStamp = Get-Date -Format "dd-MMM-yyyy HH:mm:ss"

        Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
        Write-Host -ForegroundColor Green " $message"
        "[$timeStamp] $message" | Out-File -Append -LiteralPath $verboseLogFile
    } ## end function

    ## Helper function for writing out configuration information to host, with some consistency and coloration. Uses Write-Host in one of the only good ways it should be used: displaying information to console for interactive consumption
    function _Write-ConfigMessageToHost {
        param(
            ## The header line for this config message section. If none specified, no section "header" line written
            [string]$HeaderLine,
            ## The "body" of the message, with "category" and "value" as the key/value pairs. Can be either a System.Collections.Hashtable or a System.Collections.Specialized.OrderedDictionary
            [parameter(Mandatory=$true)][PSObject]$MessageBodyInfo
        )
        if ($PSBoundParameters.ContainsKey("HeaderLine")) {Write-Host -ForegroundColor Yellow "---- $HeaderLine ----"}
        ## get the length of the longest message body "category" string (the longest key string in the hashtable), to be used for space-padding the column
        $intLongestCategoryName = ($MessageBodyInfo.Keys | Measure-Object -Maximum -Property Length).Maximum
        $MessageBodyInfo.Keys | Foreach-Object {
            $strThisKey = $_
            ## write, in green, the category info, space-padded to longer than the longest category info in the hashtable (for uniform width of column 0 in output)
            Write-Host -NoNewline -ForegroundColor Green ("{0,-$($intLongestCategoryName + 1)}: " -f $strThisKey)
            Write-Host -ForegroundColor White $MessageBodyInfo[$strThisKey]
        }
        ## add trailing newline
        Write-Host
    }

    ## items to specify whether particular sections of the code are executed (for use in working on this script itself, mostly -- should generally all be $true when script is in "normal" functioning mode)
    $preCheck = $confirmDeployment = $deployNestedESXiVMs = $deployVCSA = $setupNewVC = $addESXiHostsToVC = $configureVSANDiskGroups = $clearVSANHealthCheckAlarm = $setupVXLAN = $configureNSX = $moveVMsIntovApp = $true
} ## end begin

process {
    My-Logger "Connecting to $VIServer (before taking any action) ..."
    $viConnection = Connect-VIServer $VIServer -Credential $Credential -WarningAction SilentlyContinue
    $strDeploymentTargetType = if ($viConnection.ExtensionData.Content.About.ApiType -eq "VirtualCenter") {"vCenter"} else {"ESXi"}

    ## boolean:  Upgrade vESXi hosts to 6.5a? (Was path to patch's metadata.zip file specified?). Will also get set to $true if deploying NSX
    $bUpgradeESXiTo65a = $PSBoundParameters.ContainsKey("ESXi65aOfflineBundle")
    ## boolean:  Install NSX? (Was path to NSX OVA file specified?)
    $bDeployNSX = $PSBoundParameters.ContainsKey("NSXOVA")
    ## for when accepting $NestedESXiHostnameToIPs from pipeline (when user employed ConvertFrom-Json with a JSON cfg file), this is a PSCustomObject; need to create a hashtable from the PSCustomObject
    $hshNestedESXiHostnameToIPs = if (($NestedESXiHostnameToIPs -is [System.Collections.Hashtable]) -or ($NestedESXiHostnameToIPs -is [System.Collections.Specialized.OrderedDictionary])) {
        $NestedESXiHostnameToIPs
    } else {
        ## make a hashtable, populate key/value pairs, return hashtable
        $NestedESXiHostnameToIPs.psobject.Properties | Foreach-Object -Begin {$hshTmp = @{}} -Process {$hshTmp[$_.Name] = $_.Value} -End {$hshTmp}
    } ## end else

    if ($preCheck) {
        if ($bDeployNSX) {
            ## not testing path to NSX OVA -- already validated on parameter input
            ## check that the PowerNSX PSModule is loaded
            if (-not (Get-Module -Name "PowerNSX")) {
                Write-Host -ForegroundColor Red "`nPowerNSX Module is not loaded, please install and load PowerNSX before running script ...`nexiting"
                exit
            }
            if (-not $PSBoundParameters.ContainsKey("ESXi65aOfflineBundle")) {
                Throw "Problem:  Deploying of NSX is beinging attempted (as determined by parameters specified), but the ESXi 6.5a offline bundle parameter 'ESXi65aOfflineBundle' was not provided. Please provide a value for that parameter and let us try again"
            }
            $bUpgradeESXiTo65a = $true
        }
    }

    if ($confirmDeployment) {
        ## informative, volatile writing to console (utilizing a helper function for consistent format/output, vs. oodles of explicit Write-Host calls)
        Write-Host -ForegroundColor Magenta "`nPlease confirm the following configuration will be deployed:`n"

        $strSectionHeaderLine = "vGhetto vSphere Automated Lab Deployment Configuration"
        $hshMessageBodyInfo = [ordered]@{
            "Deployment Target" = $strDeploymentTargetType
            "Deployment Type" = $deploymentType
            "vSphere Version" = "vSphere $vSphereVersion"
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
        } ## end hsh
        if ($bDeployNSX -and $setupVXLAN) {$hshMessageBodyInfo["Private VXLAN VM Network"] = $PrivateVXLANVMNetwork}
        $hshMessageBodyInfo["VM Storage"] = $VMDatastore
        if ($strDeploymentTargetType -eq "vCenter") {
            $hshMessageBodyInfo["VM Cluster"] = $VMCluster
            $hshMessageBodyInfo["VM vApp"] = $VAppName
        } ## end if
        _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo


        $strSectionHeaderLine = "vESXi Configuration"
        $hshMessageBodyInfo = [ordered]@{
            "Num. Nested ESXi VMs" = $hshNestedESXiHostnameToIPs.Count
            "vCPU each ESXi VM" = $NestedESXivCPU
            "vMem each ESXi VM" = "$NestedESXivMemGB GB"
            "Caching VMDK size" = "$NestedESXiCachingvDiskGB GB"
            "Capacity VMDK size" = "$NestedESXiCapacityvDiskGB GB"
            $("New ESXi VM name{0}" -f $(if ($hshNestedESXiHostnameToIPs.Count -gt 1) {"s"})) = $hshNestedESXiHostnameToIPs.Keys -join ", "
            $("IP Address{0}" -f $(if ($hshNestedESXiHostnameToIPs.Count -gt 1) {"es"})) = $hshNestedESXiHostnameToIPs.Values -join ", "
            "Netmask" = $VMNetmask
            "Gateway" = $VMGateway
            "DNS" = $VMDNS
            "NTP" = $VMNTP
            "Syslog" = $VMSyslog
            "Enable SSH" = $VMSSH
            "Create VMFS Volume" = $VMVMFS
            "Root Password" = $VMPassword
            "Update to 6.5a" = $bUpgradeESXiTo65a
        } ## end hsh
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
            "DNS" = $VMDNS
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
                "Enable SSH" = $NSXSSHEnable
                "Enable CEIP" = $NSXCEIPEnable
                "UI Password" = $NSXUIPassword
                "CLI Password" = $NSXCLIPassword
            } ## end hsh
            _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo
        } ## end if

        ## do some math
        $esxiTotalCPU = $hshNestedESXiHostnameToIPs.Count * $NestedESXivCPU
        $esxiTotalMemory = $hshNestedESXiHostnameToIPs.Count * $NestedESXivMemGB
        $esxiTotalStorage = ($hshNestedESXiHostnameToIPs.Count * $NestedESXiCachingvDiskGB) + ($hshNestedESXiHostnameToIPs.count * $NestedESXiCapacityvDiskGB)
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

# # this is just for returning, for demonstration purposes, what are the parameters and their values
# $hshOut = [ordered]@{}
# Get-Variable -Name (Get-Command -Name $PSCmdlet.MyInvocation.InvocationName).Parameters.Values.Name -ErrorAction:SilentlyContinue | Foreach-Object {$hshOut[$_.Name] = $_.Value}
# $hshOut

# exit
        Write-Host -ForegroundColor Magenta "`nWould you like to proceed with this deployment?`n"
        $answer = Read-Host -Prompt "Do you accept (Y or N)"
        ## need just one comparison -- "-ne" is case-insensitive by default; but, for the sake of explicitness, using the "-ine" comparison operator
        if ($answer -ine "y") {
            Disconnect-VIServer -Server $viConnection -Confirm:$false
            exit
        }
        # Clear-Host
    } ## end of Confirm Deployment section

    $vmhost = if ($strDeploymentTargetType -eq "ESXi") {
        Get-VMHost -Server $viConnection
    } else {
        $cluster = Get-Cluster -Server $viConnection -Name $VMCluster
        $datacenter = $cluster | Get-Datacenter
        $cluster | Get-VMHost -State:Connected | Get-Random
    } ## end else

    ## get the datastore to use
    $datastore = Get-Datastore -Server $viConnection -Name $VMDatastore -VMHost $vmhost | Select-Object -First 1
    if ($datastore.Type -eq "vsan") {
        My-Logger "VSAN Datastore detected, enabling Fake SCSI Reservations ..."
        Get-AdvancedSetting -Entity $vmhost -Name "VSAN.FakeSCSIReservations" | Set-AdvancedSetting -Value 1 -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
    } ## end if

    ## get the virtual portgroup to which to connect new VM objects' network adapter(s)
    try {
        $network = Get-VDPortgroup -Server $viConnection -Name $VMNetwork -ErrorAction:Stop | Select -First 1
        if ($bDeployNSX) {$privateNetwork = Get-VDPortgroup -Server $viConnection -Name $PrivateVXLANVMNetwork -ErrorAction:Stop | Select-Object -First 1}
    } catch {
        My-Logger "Had issue getting vPG $VMNetwork from switch as VDS. Will try as VSS ..."
        $network = Get-VirtualPortGroup -Server $viConnection -Name $VMNetwork | Select-Object -First 1
        if ($bDeployNSX) {$privateNetwork = Get-VirtualPortGroup -Server $viConnection -Name $PrivateVXLANVMNetwork | Select-Object -First 1}
    } ## end catch

    if ($deployNestedESXiVMs) {
        $dteStartOnAllVM = Get-Date
        ## create, by Import-VApp, the vESXi VMs, then Set-NetworkAdapter, Set-HardDisk, update VM config (if deploy target is ESXi), then power on
        $hshNestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
            $VMName = $_.Key
            $VMIPAddress = $_.Value
            $dteStartThisVM = Get-Date
            My-Logger "Deploying Nested ESXi VM $VMName ..."

            ## hashtable to use for parameter splatting so that we can conditional build the params, and then have a single workflow (one invocation spot for Import-VApp)
            $hshParamsForImportVApp = @{
                Name = $VMName
                Server = $viConnection
                Source = $NestedESXiApplianceOVA
                VMHost = $vmhost
                Datastore = $datastore
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
                    "guestinfo.dns" = $VMDNS.IPAddressToString
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
                $ovfconfig.common.guestinfo.dns.value = $VMDNS.IPAddressToString
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
            My-Logger "Correcting missing dvFilter settings for Eth1 ..."
            $vm | New-AdvancedSetting -name "ethernet1.filter4.name" -value "dvfilter-maclearn" -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            $vm | New-AdvancedSetting -Name "ethernet1.filter4.onFailure" -value "failOpen" -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            ## if this is to an ESXi host, need to set first NetworkAdapter's portgroup here (when deploying to vCenter, not necessary, as NetworkAdapters' PortGroup set via OVF config)
            if ($strDeploymentTargetType -eq "ESXi") {
                My-Logger "Updating VM Network ..."
                $vm | Get-NetworkAdapter -Name "Network adapter 1" | Set-NetworkAdapter -Portgroup $network -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                Start-Sleep -Seconds 5
            } ## end if

            ## determine which portgroup to use for second network adapter, then just have one call to Set-NetworkAdapter
            $oPortgroupForSecondNetAdapter = if ($bDeployNSX) {$privateNetwork} else {$network}
            My-Logger "Connecting Eth1 to $oPortgroupForSecondNetAdapter ..."
            $vm | Get-NetworkAdapter -Name "Network adapter 2" | Set-NetworkAdapter -Portgroup $oPortgroupForSecondNetAdapter -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vCPU Count to $NestedESXivCPU & vMem to $NestedESXivMemGB GB ..."
            Set-VM -Server $viConnection -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMemGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vSAN Caching VMDK size to $NestedESXiCachingvDiskGB GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXiCachingvDiskGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Updating vSAN Capacity VMDK size to $NestedESXiCapacityvDiskGB GB ..."
            Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $NestedESXiCapacityvDiskGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            if ($strDeploymentTargetType -eq "ESXi") {
                ## make a new VMConfigSpec with which to reconfigure this VM
                $spec = New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{
                    ## make a new ExtraConfig object that is the concatenation of the original ExtraConfig and an array of new OptionValue objects created from the key/value pairs of the given hashtable
                    ExtraConfig = $vm.ExtensionData.Config.ExtraConfig + @(
                        $hshNewExtraConfigKeysAndValues.Keys | Foreach-Object {New-Object -Type VMware.Vim.OptionValue -Property @{Key = $_; Value = $hshNewExtraConfigKeysAndValues[$_]}}
                    ) ## end of ExtraConfig array of config OptionValue objects
                } ## end new-object

                My-Logger "Adding guestinfo customization properties to $VMName by reconfiguring the VM ..."
                $task = $vm.ExtensionData.ReconfigVM_Task($spec)
                Get-Task -Id $task | Wait-Task | Out-Null
            } ## end if
            else {My-Logger "No additional guestinfo customization properties to set on $VMName, continuing ..."}

            My-Logger "Powering On $VMName ..."
            Start-VM -Server $viConnection -VM $vm -RunAsync -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            My-Logger ("Timespan for VM ${VMName}: {0}" -f ((Get-Date) - $dteStartThisVM))
        } ## end foreach-object
        My-Logger ("Timespan for all vESXi VMs: {0}" -f ((Get-Date) - $dteStartOnAllVM))
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
            $ovfconfig.common.vsm_dns1_0.value = $VMDNS.IPAddressToString
            $ovfconfig.common.vsm_domain_0.value = $VMDomain
            $ovfconfig.common.vsm_isSSHEnabled.value = $NSXSSHEnable.ToString()
            $ovfconfig.common.vsm_isCEIPEnabled.value = $NSXCEIPEnable.ToString()
            $ovfconfig.common.vsm_cli_passwd_0.value = $NSXUIPassword
            $ovfconfig.common.vsm_cli_en_passwd_0.value = $NSXCLIPassword

            My-Logger "Deploying NSX VM $NSXDisplayName ..."
            $vm = Import-VApp -Source $NSXOVA -OvfConfiguration $ovfconfig -Name $NSXDisplayName -Location $cluster -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin

            My-Logger "Updating vCPU Count to $NSXvCPU & vMem to $NSXvMemGB GB ..."
            Set-VM -Server $viConnection -VM $vm -NumCpu $NSXvCPU -MemoryGB $NSXvMemGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Powering On $NSXDisplayName ..."
            $vm | Start-Vm -RunAsync | Out-Null
            My-Logger ("Timespan for deploying NSX Manager appliance: {0}" -f ((Get-Date) - $dteStartThisVM))
        } ## end if
        else {My-Logger "Not deploying NSX -- connected to an ESXi host ..."}
    } ## end of deploying NSX

    if ($bUpgradeESXiTo65a) {
        $hshNestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
            $dteStartThisVM = Get-Date
            $VMName = $_.Key
            $VMIPAddress = $_.Value

            My-Logger "Connecting directly to $VMName for ESXi upgrade ..."
            $vESXi = Connect-VIServer -Server $VMIPAddress -User root -Password $VMPassword -WarningAction SilentlyContinue

            My-Logger "Entering Maintenance Mode ..."
            Set-VMHost -VMhost $VMIPAddress -State Maintenance -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Upgrading $VMName to ESXi 6.5a ..."
            Install-VMHostPatch -VMHost $VMIPAddress -LocalPath $ESXi65aOfflineBundle -HostUsername root -HostPassword $VMPassword -WarningAction SilentlyContinue -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Rebooting $VMName ..."
            Restart-VMHost $VMIPAddress -RunAsync -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Disconnecting from new ESXi host ..."
            Disconnect-VIServer $vESXi -Confirm:$false
            My-Logger ("Timespan for patching VMHost ${VMName}: {0}" -f ((Get-Date) - $dteStartThisVM))
        }
    }

    if ($deployVCSA) {
        $dteStartThisVCSA = Get-Date
        ## the name of the key (specific to the deployment target type of ESXi or vCenter), and the name of the JSON file that has the respcetive VCSA config
        $strKeynameForOvfConfig, $strCfgJsonFilename = if ($strDeploymentTargetType -eq "ESXi") {"esxi", "embedded_vCSA_on_ESXi.json"} else {"vc", "embedded_vCSA_on_VC.json"}

        # Deploy using the VCSA CLI Installer
        $config = (Get-Content -Raw "${VCSAInstallerPath}\vcsa-cli-installer\templates\install\${strCfgJsonFilename}") | ConvertFrom-Json
        ## these with "$strKeynameForOvfConfig" in the path are used for both deployment types, but have one different key in them
        $config.'new.vcsa'.$strKeynameForOvfConfig.hostname = $VIServer
        $config.'new.vcsa'.$strKeynameForOvfConfig.username = $Credential.UserName
        $config.'new.vcsa'.$strKeynameForOvfConfig.password = $Credential.GetNetworkCredential().Password
        $config.'new.vcsa'.$strKeynameForOvfConfig.'deployment.network' = $VMNetwork
        $config.'new.vcsa'.$strKeynameForOvfConfig.datastore = $datastore
        ## only add these two config items if the deployment target is vCenter
        if ($strDeploymentTargetType -eq "vCenter") {
            $config.'new.vcsa'.$strKeynameForOvfConfig.datacenter = $datacenter.name
            $config.'new.vcsa'.$strKeynameForOvfConfig.target = $VMCluster
        } ## end
        $config.'new.vcsa'.appliance.'thin.disk.mode' = $true
        $config.'new.vcsa'.appliance.'deployment.option' = $VCSADeploymentSize
        $config.'new.vcsa'.appliance.name = $VCSADisplayName
        $config.'new.vcsa'.network.'ip.family' = "ipv4"
        $config.'new.vcsa'.network.mode = "static"
        $config.'new.vcsa'.network.ip = $VCSAIPAddress.IPAddressToString
        $config.'new.vcsa'.network.'dns.servers'[0] = $VMDNS.IPAddressToString
        $config.'new.vcsa'.network.prefix = $VCSAPrefix.ToString()
        $config.'new.vcsa'.network.gateway = $VMGateway.IPAddressToString
        $config.'new.vcsa'.network.'system.name' = $VCSAHostname
        $config.'new.vcsa'.os.password = $VCSARootPassword
        $config.'new.vcsa'.os.'ssh.enable' = $VCSASSHEnable.ToBool()
        $config.'new.vcsa'.sso.password = $VCSASSOPassword
        $config.'new.vcsa'.sso.'domain-name' = $VCSASSODomainName
        $config.'new.vcsa'.sso.'site-name' = $VCSASSOSiteName

        My-Logger "Creating VCSA JSON Configuration file for deployment ..."
        $config | ConvertTo-Json | Set-Content -Path "$($ENV:Temp)\jsontemplate.json"

        My-Logger "Deploying the VCSA ..."
        Invoke-Command -ScriptBlock {& "${VCSAInstallerPath}\vcsa-cli-installer\win32\vcsa-deploy.exe" install --no-esx-ssl-verify --accept-eula --acknowledge-ceip "$($ENV:Temp)\jsontemplate.json"} | Out-File -Append -LiteralPath $verboseLogFile
        ## teeing object so that, while all actions get written to verbose log, we can display the OVF Tool disk progress
        # Invoke-Command -ScriptBlock {& "${VCSAInstallerPath}\vcsa-cli-installer\win32\vcsa-deploy.exe" install --no-esx-ssl-verify --accept-eula --acknowledge-ceip "$($ENV:Temp)\jsontemplate.json"} | Tee-Object -Append -FilePath $verboseLogFile | Select-String "disk progress"
        My-Logger ("Timespan for deploying VCSA ${VCSADisplayName}: {0}" -f ((Get-Date) - $dteStartThisVCSA))
    } ## end if deployVCSA

    if ($moveVMsIntovApp -and ($strDeploymentTargetType -eq "vCenter")) {
        My-Logger "Creating vApp $VAppName ..."
        $VApp = New-VApp -Name $VAppName -Server $viConnection -Location $cluster

        if ($deployNestedESXiVMs) {
            My-Logger "Moving Nested ESXi VMs into vApp $VAppName ..."
            Get-VM -Name ($hshNestedESXiHostnameToIPs.Keys | Foreach-Object {$_}) -Server $viConnection | Move-VM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        } ## end if

        if ($deployVCSA) {
            My-Logger "Moving $VCSADisplayName into vApp $VAppName ..."
            Get-VM -Name $VCSADisplayName -Server $viConnection | Move-VM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        } ## end if

        if ($bDeployNSX) {
            My-Logger "Moving $NSXDisplayName into vApp $VAppName ..."
            Get-VM -Name $NSXDisplayName -Server $viConnection | Move-VM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        } ## end if
    } ## end if
    else {My-Logger "Not creating vApp $VAppName"}

    My-Logger "Disconnecting from $VIServer ..."
    Disconnect-VIServer $viConnection -Confirm:$false


    if ($setupNewVC) {
        My-Logger "Connecting to the new VCSA ..."
        $vc = Connect-VIServer $VCSAIPAddress.IPAddressToString -User "administrator@$VCSASSODomainName" -Password $VCSASSOPassword -WarningAction SilentlyContinue

        My-Logger "Creating Datacenter $NewVCDatacenterName ..."
        New-Datacenter -Server $vc -Name $NewVCDatacenterName -Location (Get-Folder -Type Datacenter -Server $vc) | Out-File -Append -LiteralPath $verboseLogFile

        My-Logger "Creating VSAN Cluster $NewVCVSANClusterName ..."
        New-Cluster -Server $vc -Name $NewVCVSANClusterName -Location (Get-Datacenter -Name $NewVCDatacenterName -Server $vc) -DrsEnabled -VsanEnabled -VsanDiskClaimMode 'Manual' | Out-File -Append -LiteralPath $verboseLogFile

        if ($addESXiHostsToVC) {
            $hshNestedESXiHostnameToIPs.GetEnumerator() | sort -Property Value | Foreach-Object {
                $VMName = $_.Key
                $VMIPAddress = $_.Value

                $targetVMHost = if ($AddHostByDnsName) {$VMName} else {$VMIPAddress}

                My-Logger "Adding ESXi host $targetVMHost to Cluster $NewVCVSANClusterName ..."
                Add-VMHost -Server $vc -Location (Get-Cluster -Name $NewVCVSANClusterName) -User "root" -Password $VMPassword -Name $targetVMHost -Force | Out-File -Append -LiteralPath $verboseLogFile
            } ## end foreach-object
        } ## end if addESXiHostsToVC

        if ($bDeployNSX -and $setupVXLAN) {
            My-Logger "Creating VDS $VDSName ..."
            $vds = New-VDSwitch -Server $vc -Name $VDSName -Location (Get-Datacenter -Name $NewVCDatacenterName)

            My-Logger "Creating new VXLAN DVPortgroup $VXLANDVPortgroup ..."
            $vxlanDVPG = New-VDPortgroup -Server $vc -Name $VXLANDVPortgroup -Vds $vds

            Get-Cluster -Server $vc -Name $NewVCVSANClusterName | Get-VMHost | Foreach-Object {
                $oThisVMHost = $_
                My-Logger "Adding $($oThisVMHost.name) to VDS ..."
                Add-VDSwitchVMHost -Server $vc -VDSwitch $vds -VMHost $oThisVMHost | Out-File -Append -LiteralPath $verboseLogFile

                My-Logger "Adding vmmnic1 to VDS ..."
                $vmnic = $oThisVMHost | Get-VMHostNetworkAdapter -Physical -Name vmnic1
                Add-VDSwitchPhysicalNetworkAdapter -Server $vc -DistributedSwitch $vds -VMHostPhysicalNic $vmnic -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                $vmk0 = Get-VMHostNetworkAdapter -Server $vc -Name vmk0 -VMHost $oThisVMHost
                $lastNetworkOcet = $vmk0.ip.Split('.')[-1]
                ## make the new VMKernel portgroup IP from the first three octects of the given Subnet address and the last octet of this VMHost's management IP address
                $vxlanVmkIP = ($VXLANSubnet.IPAddressToString.Split(".")[0..2],$lastNetworkOcet | Foreach-Object {$_}) -join "."

                My-Logger "Adding VXLAN VMKernel $vxlanVmkIP to VDS ..."
                New-VMHostNetworkAdapter -VMHost $oThisVMHost -PortGroup $VXLANDVPortgroup -VirtualSwitch $vds -IP $vxlanVmkIP -SubnetMask $VXLANNetmask.IPAddressToString -Mtu 1600 | Out-File -Append -LiteralPath $verboseLogFile
            } ## end foreach-object
        } ## end bDeployNSX and setupVXLAN

        if ($configureVSANDiskGroups) {
            $dteStartThisSection = Get-Date

            My-Logger "Enabling VSAN Space Efficiency/De-Dupe & disabling VSAN Health Check on cluster $NewVCVSANClusterName ..."
            Get-VsanClusterConfiguration -Server $vc -Cluster $NewVCVSANClusterName | Set-VsanClusterConfiguration -SpaceEfficiencyEnabled $true -HealthCheckIntervalMinutes 0 | Out-File -Append -LiteralPath $verboseLogFile

            ## create the new VSAN disk groups, but in parallel (running asynchronously); will wait for the tasks to complete in next step
            $arrTasksForNewVSanDiskGroup = Get-Cluster -Server $vc | Get-VMHost | Foreach-Object {
                $oThisVMHost = $_
                $luns = $oThisVMHost | Get-ScsiLun | Select-Object CanonicalName, CapacityGB

                My-Logger "Querying disks on ESXi host $($oThisVMHost.Name) to create VSAN Diskgroups ..."
                $vsanCacheDisk = ($luns | Where-Object {$_.CapacityGB -eq $NestedESXiCachingvDiskGB} | Get-Random).CanonicalName
                $vsanCapacityDisk = ($luns | Where-Object {$_.CapacityGB -eq $NestedESXiCapacityvDiskGB} | Get-Random).CanonicalName

                My-Logger "Creating VSAN DiskGroup for $oThisVMHost (asynchronously) ..."
                New-VsanDiskGroup -Server $vc -VMHost $oThisVMHost -SsdCanonicalName $vsanCacheDisk -DataDiskCanonicalName $vsanCapacityDisk -RunAsync
            } ## end foreach-object

            ## then, wait for the tasks to finish, and return the resulting objects to the verbose log file
            My-Logger ("Waiting for VSAN DiskGroup creation to finish for {0} host{1} ..." -f $arrTasksForNewVSanDiskGroup.Count, $(if ($arrTasksForNewVSanDiskGroup.Count -ne 1) {"s"}))
            Wait-Task -Task $arrTasksForNewVSanDiskGroup | Out-File -Append -LiteralPath $verboseLogFile
            My-Logger ("Timespan for configuring VSAN items: {0}" -f ((Get-Date) - $dteStartThisSection))
        } ## end configureVSANDiskGroups

        if ($clearVSANHealthCheckAlarm) {
            My-Logger "Clearing default VSAN Health Check Alarms, not applicable in Nested ESXi env ..."
            $alarmMgr = Get-View AlarmManager -Server $vc
            Get-Cluster -Server $vc | Where-Object {$_.ExtensionData.TriggeredAlarmState} | Foreach-Object {
                $cluster = $_
                $Cluster.ExtensionData.TriggeredAlarmState | Foreach-Object {$alarmMgr.AcknowledgeAlarm($_.Alarm,$cluster.ExtensionData.MoRef)}
            } ## end foreach-object
        } ## end if

        # Exit maintanence mode in case patching was done earlier
        Get-Cluster -Server $vc | Get-VMHost -State:Maintenance | Set-VMHost -State Connected -RunAsync -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

        My-Logger "Disconnecting from new VCSA ..."
        Disconnect-VIServer $vc -Confirm:$false
    } ## end setupNewVC

    if ($configureNSX -and $bDeployNSX -and $setupVXLAN) {
        if (!(Connect-NSXServer -Server $NSXHostname -Username admin -Password $NSXUIPassword -DisableVIAutoConnect -WarningAction SilentlyContinue)) {
            Write-Host -ForegroundColor Red "Unable to connect to NSX Manager, please check the deployment"
            exit
        } else {My-Logger "Successfully logged into NSX Manager $NSXHostname ..."}

        $ssoUsername = "administrator@$VCSASSODomainName"
        My-Logger "Registering NSX Manager with vCenter Server $VCSAHostname ..."
        $vcConfig = Set-NsxManager -vCenterServer $VCSAHostname -vCenterUserName $ssoUsername -vCenterPassword $VCSASSOPassword

        My-Logger "Registering NSX Manager with vCenter SSO $VCSAHostname ..."
        $ssoConfig = Set-NsxManager -SsoServer $VCSAHostname -SsoUserName $ssoUsername -SsoPassword $VCSASSOPassword -AcceptAnyThumbprint

        My-Logger "Disconnecting from NSX Manager ..."
        Disconnect-NsxServer
    }

    $EndTime = Get-Date
    $duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

    My-Logger "vSphere $vSphereVersion Lab Deployment Complete!"
    My-Logger "StartTime:  $($StartTime.ToString('dd-MMM-yyyy HH:mm:ss'))"
    My-Logger "  EndTime:  $($EndTime.ToString('dd-MMM-yyyy HH:mm:ss'))"
    My-Logger " Duration:  $duration minutes"
} ## end process