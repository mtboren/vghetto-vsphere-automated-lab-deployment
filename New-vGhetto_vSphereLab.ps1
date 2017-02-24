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
    [System.Management.Automation.PSCredential]$Credential = (Get-Credential -Message "Credential to use for initially connecting to vCenter or ESXi host for vSphere lab deployment" -UserName "administrator@vsphere.local"),
    ## Specifies whether deployment is to an ESXi host or vCenter Server.  Either ESXi or vCenter
    [parameter(ValueFromPipelineByPropertyName=$true)][ValidateSet("ESXi","vCenter")]$DeploymentTarget = "vCenter",

    ## Full path to the OVA of the Nested ESXi 6.5 virtual appliance. Example: "C:\temp\Nested_ESXi6.5_Appliance_Template_v1.ova"
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -Path $_})][string]$NestedESXiApplianceOVA,
    ## Full Path to where the contents of the VCSA 6.5 ISO can be accessed. Say, either a folder into which the ISO was extracted, or a drive letter as which the ISO is mounted. For example, "C:\Temp\VMware-VCSA-all-6.5.0-4944578" or "D:\"
    [parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -PathType Container -Path $_})][string]$VCSAInstallerPath,
    ## Full path to the vmw-ESXi-6.5.0-metadata.zip file in the full, extracted ESXi 6.5a VMHost offline update bundle. If not specified, the new ESXi hosts will not be updated to this new version. The offline bundle zip file should be extracted into a folder that matches the update profile's name (e.g., "ESXi650-201701001"). Example:  C:\temp\ESXi650-201701001\vmw-ESXi-6.5.0-metadata.zip
    [parameter(ValueFromPipelineByPropertyName=$true)][ValidateScript({Test-Path -Path $_})][string]$ESXi65aOfflineBundle,

    ## Information about the nested ESXi VMs to deploy. Expects a hashtable with ESXi host shortnames as keys, and the corresponding IP addresses as values
    [parameter(ValueFromPipelineByPropertyName=$true)][System.Collections.Hashtable]$NestedESXiHostnameToIPs = @{
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
    ## VCSA Deployment Configuration -- Guest hostname for the new VCSA VM. Change to IP if you don't have valid DNS services in play
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
    $random_string = -join ((65..90) + (97..122) | Get-Random -Count 8 | % {[char]$_})
    $VAppName = "vGhetto-Nested-vSphere-Lab-$vSphereVersion-$random_string"

    ## hashtable for VCSA "size" name to resource sizing correlation
    $vcsaSize2MemoryStorageMap = @{
        tiny   = @{cpu = 2;  mem = 10; disk = 250};
        small  = @{cpu = 4;  mem = 16; disk = 290};
        medium = @{cpu = 8;  mem = 24; disk = 425};
        large  = @{cpu = 16; mem = 32; disk = 640};
        xlarge = @{cpu = 24; mem = 48; disk = 980}
    } ## end config hashtable

    Function My-Logger {
        param (
            [Parameter(Mandatory=$true)][String]$message
        ) ## end param

        $timeStamp = Get-Date -Format "MM-dd-yyyy_hh:mm:ss"

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

    $preCheck = 1
    $confirmDeployment = 1
    $deployNestedESXiVMs = 1
    $deployVCSA = 1
    $setupNewVC = 1
    $addESXiHostsToVC = 1
    $configureVSANDiskGroups = 1
    $clearVSANHealthCheckAlarm = 1
    $setupVXLAN = 1
    $configureNSX = 1
    $moveVMsIntovApp = 1
} ## end begin

process {
    ## boolean:  Upgrade vESXi hosts to 6.5a? (Was path to patch's metadata.zip file specified?)
    $bUpgradeESXiTo65a = $PSBoundParameters.ContainsKey("ESXi65aOfflineBundle")
    ## boolean:  Install NSX? (Was path to NSX OVA file specified?)
    $bDeployNSX = $PSBoundParameters.ContainsKey("NSXOVA")

    if($preCheck -eq 1) {
        if($bDeployNSX) {
            ## not testing path to NSX OVA -- already validated on parameter input
            ## check that the PowerNSX PSModule is loaded
            if(-not (Get-Module -Name "PowerNSX")) {
                Write-Host -ForegroundColor Red "`nPowerNSX Module is not loaded, please install and load PowerNSX before running script ...`nexiting"
                exit
            }
            $bUpgradeESXiTo65a = $true
        }
    }

    if ($confirmDeployment -eq 1) {
        ## informative, volatile writing to console (utilizing a helper function for consistent format/output, vs. oodles of explicit Write-Host calls)
        Write-Host -ForegroundColor Magenta "`nPlease confirm the following configuration will be deployed:`n"

        $strSectionHeaderLine = "vGhetto vSphere Automated Lab Deployment Configuration"
        $hshMessageBodyInfo = [ordered]@{
            "Deployment Target" = $DeploymentTarget
            "Deployment Type" = $deploymentType
            "vSphere Version" = "vSphere $vSphereVersion"
            "Nested ESXi Image Path" = $NestedESXiApplianceOVA
            "VCSA Image Path" = $VCSAInstallerPath
        } ## end hsh
        if ($bDeployNSX) {$hshMessageBodyInfo["NSX Image Path"] = $NSXOVA}
        if ($bUpgradeESXiTo65a) {$hshMessageBodyInfo["Extracted ESXi 6.5a Offline Patch Bundle Path"] = $ESXi65aOfflineBundle}
        _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo


        $strSectionHeaderLine = if ($DeploymentTarget -eq "ESXI") {"Physical ESXi Deployment Target Configuration"} else {"vCenter Server Deployment Target Configuration"}
        $hshMessageBodyInfo = [ordered]@{
            $(if ($DeploymentTarget -eq "ESXI") {"ESXi Address"} else {"vCenter Server Address"}) = $VIServer
            "Username" = $Credential.UserName
            "VM Network" = $VMNetwork
        } ## end hsh
        if ($bDeployNSX -and $setupVXLAN -eq 1) {$hshMessageBodyInfo["Private VXLAN VM Network"] = $PrivateVXLANVMNetwork}
        $hshMessageBodyInfo["VM Storage"] = $VMDatastore
        if ($DeploymentTarget -eq "vCenter") {
            $hshMessageBodyInfo["VM Cluster"] = $VMCluster
            $hshMessageBodyInfo["VM vApp"] = $VAppName
        } ## end if
        _Write-ConfigMessageToHost -HeaderLine $strSectionHeaderLine -MessageBodyInfo $hshMessageBodyInfo


        $strSectionHeaderLine = "vESXi Configuration"
        $hshMessageBodyInfo = [ordered]@{
            "Num. Nested ESXi VMs" = $NestedESXiHostnameToIPs.Count
            "vCPU each ESXi VM" = $NestedESXivCPU
            "vMem each ESXi VM" = "$NestedESXivMemGB GB"
            "Caching VMDK size" = "$NestedESXiCachingvDiskGB GB"
            "Capacity VMDK size" = "$NestedESXiCapacityvDiskGB GB"
            $("IP Address{0}" -f $(if ($NestedESXiHostnameToIPs.Count -gt 1) {"es"})) = $NestedESXiHostnameToIPs.Values -join ", "
            "Netmask" = $VMNetmask
            "Gateway" = $VMGateway
            "DNS" = $VMDNS
            "NTP" = $VMNTP
            "Syslog" = $VMSyslog
            "Enable SSH" = $VMSSH
            "Create VMFS Volume" = $VMVMFS
            "Root Password" = $VMPassword
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
            "Hostname" = $VCSAHostname
            "IP Address" = $VCSAIPAddress
            "Netmask" = $VMNetmask
            "Gateway" = $VMGateway
        } ## end hsh
        if ($bDeployNSX -and $setupVXLAN -eq 1) {
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
        $esxiTotalCPU = $NestedESXiHostnameToIPs.Count * $NestedESXivCPU
        $esxiTotalMemory = $NestedESXiHostnameToIPs.Count * $NestedESXivMemGB
        $esxiTotalStorage = ($NestedESXiHostnameToIPs.Count * $NestedESXiCachingvDiskGB) + ($NestedESXiHostnameToIPs.count * $NestedESXiCapacityvDiskGB)
        $vcsaTotalCPU = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.cpu
        $vcsaTotalMemory = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.mem
        $vcsaTotalStorage = $vcsaSize2MemoryStorageMap.$VCSADeploymentSize.disk

        Write-Host -ForegroundColor Yellow "`n---- Resource Requirements ----"
        Write-Host -NoNewline -ForegroundColor Green "ESXi VM CPU: "
        Write-Host -NoNewline -ForegroundColor White $esxiTotalCPU
        Write-Host -NoNewline -ForegroundColor Green ", ESXi VM Memory: "
        Write-Host -NoNewline -ForegroundColor White $esxiTotalMemory "GB"
        Write-Host -NoNewline -ForegroundColor Green ", ESXi VM Storage: "
        Write-Host -ForegroundColor White $esxiTotalStorage "GB"
        Write-Host -NoNewline -ForegroundColor Green "VCSA VM CPU: "
        Write-Host -NoNewline -ForegroundColor White $vcsaTotalCPU
        Write-Host -NoNewline -ForegroundColor Green ", VCSA VM Memory: "
        Write-Host -NoNewline -ForegroundColor White $vcsaTotalMemory "GB"
        Write-Host -NoNewline -ForegroundColor Green ", VCSA VM Storage: "
        Write-Host -ForegroundColor White $vcsaTotalStorage "GB"

        if($bDeployNSX) {
            $nsxTotalCPU = $NSXvCPU
            $nsxTotalMemory = $NSXvMemGB
            $nsxTotalStorage = 60
            Write-Host -NoNewline -ForegroundColor Green "NSX VM CPU: "
            Write-Host -NoNewline -ForegroundColor White $nsxTotalCPU
            Write-Host -NoNewline -ForegroundColor Green ", NSX VM Memory: "
            Write-Host -NoNewline -ForegroundColor White $nsxTotalMemory "GB "
            Write-Host -NoNewline -ForegroundColor Green ", NSX VM Storage: "
            Write-Host -ForegroundColor White $nsxTotalStorage "GB"
        }

        Write-Host -ForegroundColor White "---------------------------------------------"
        Write-Host -NoNewline -ForegroundColor Green "Total CPU: "
        Write-Host -ForegroundColor White ($esxiTotalCPU + $vcsaTotalCPU + $nsxTotalCPU)
        Write-Host -NoNewline -ForegroundColor Green "Total Memory: "
        Write-Host -ForegroundColor White ($esxiTotalMemory + $vcsaTotalMemory + $nsxTotalMemory) "GB"
        Write-Host -NoNewline -ForegroundColor Green "Total Storage: "
        Write-Host -ForegroundColor White ($esxiTotalStorage + $vcsaTotalStorage + $nsxTotalStorage) "GB"

# this is just for returning, for demonstration purposes, what are the parameters and their values
$hshOut = [ordered]@{}
Get-Variable -Name (Get-Command -Name $PSCmdlet.MyInvocation.InvocationName).Parameters.Values.Name -ErrorAction:SilentlyContinue | Foreach-Object {$hshOut[$_.Name] = $_.Value}
$hshOut

exit
        Write-Host -ForegroundColor Magenta "`nWould you like to proceed with this deployment?`n"
        $answer = Read-Host -Prompt "Do you accept (Y or N)"
        if($answer -ne "Y" -or $answer -ne "y") {
            exit
        }
        Clear-Host
    }

    My-Logger "Connecting to $VIServer ..."
    $viConnection = Connect-VIServer $VIServer -Credential $Credential -WarningAction SilentlyContinue

    if($DeploymentTarget -eq "ESXI") {
        $datastore = Get-Datastore -Server $viConnection -Name $VMDatastore
        if($VirtualSwitchType -eq "VSS") {
            $network = Get-VirtualPortGroup -Server $viConnection -Name $VMNetwork
            if($bDeployNSX) {
                $privateNetwork = Get-VirtualPortGroup -Server $viConnection -Name $PrivateVXLANVMNetwork
            }
        } else {
            $network = Get-VDPortgroup -Server $viConnection -Name $VMNetwork
            if($bDeployNSX) {
                $privateNetwork = Get-VDPortgroup -Server $viConnection -Name $PrivateVXLANVMNetwork
            }
        }
        $vmhost = Get-VMHost -Server $viConnection

        if($datastore.Type -eq "vsan") {
            My-Logger "VSAN Datastore detected, enabling Fake SCSI Reservations ..."
            Get-AdvancedSetting -Entity $vmhost -Name "VSAN.FakeSCSIReservations" | Set-AdvancedSetting -Value 1 -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        }
    } else {
        $datastore = Get-Datastore -Server $viConnection -Name $VMDatastore | Select -First 1
        if($VirtualSwitchType -eq "VSS") {
            $network = Get-VirtualPortGroup -Server $viConnection -Name $VMNetwork | Select -First 1
            if($bDeployNSX) {
                $privateNetwork = Get-VirtualPortGroup -Server $viConnection -Name $PrivateVXLANVMNetwork | Select -First 1
            }
        } else {
            $network = Get-VDPortgroup -Server $viConnection -Name $VMNetwork | Select -First 1
            if($bDeployNSX) {
                $privateNetwork = Get-VDPortgroup -Server $viConnection -Name $PrivateVXLANVMNetwork | Select -First 1
            }
        }
        $cluster = Get-Cluster -Server $viConnection -Name $VMCluster
        $datacenter = $cluster | Get-Datacenter
        $vmhost = $cluster | Get-VMHost | Select -First 1

        if($datastore.Type -eq "vsan") {
            My-Logger "VSAN Datastore detected, enabling Fake SCSI Reservations ..."
            Get-AdvancedSetting -Entity $vmhost -Name "VSAN.FakeSCSIReservations" | Set-AdvancedSetting -Value 1 -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        }
    }

    if($deployNestedESXiVMs -eq 1) {
        if($DeploymentTarget -eq "ESXI") {
            $NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
                $VMName = $_.Key
                $VMIPAddress = $_.Value

                My-Logger "Deploying Nested ESXi VM $VMName ..."
                $vm = Import-VApp -Server $viConnection -Source $NestedESXiApplianceOVA -Name $VMName -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin

                My-Logger "Updating VM Network ..."
                $vm | Get-NetworkAdapter -Name "Network adapter 1" | Set-NetworkAdapter -Portgroup $network -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                sleep 5

                if($bDeployNSX) {
                    $vm | Get-NetworkAdapter -Name "Network adapter 2" | Set-NetworkAdapter -Portgroup $privateNetwork -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                } else {
                    $vm | Get-NetworkAdapter -Name "Network adapter 2" | Set-NetworkAdapter -Portgroup $network -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                }

                My-Logger "Updating vCPU Count to $NestedESXivCPU & vMEM to $NestedESXivMemGB GB ..."
                Set-VM -Server $viConnection -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMemGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                My-Logger "Updating vSAN Caching VMDK size to $NestedESXiCachingvDiskGB GB ..."
                Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXiCachingvDiskGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                My-Logger "Updating vSAN Capacity VMDK size to $NestedESXiCapacityvDiskGB GB ..."
                Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $NestedESXiCapacityvDiskGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                $orignalExtraConfig = $vm.ExtensionData.Config.ExtraConfig
                $a = New-Object VMware.Vim.OptionValue
                $a.key = "guestinfo.hostname"
                $a.value = $VMName
                $b = New-Object VMware.Vim.OptionValue
                $b.key = "guestinfo.ipaddress"
                $b.value = $VMIPAddress
                $c = New-Object VMware.Vim.OptionValue
                $c.key = "guestinfo.netmask"
                $c.value = $VMNetmask.IPAddressToString
                $d = New-Object VMware.Vim.OptionValue
                $d.key = "guestinfo.gateway"
                $d.value = $VMGateway.IPAddressToString
                $e = New-Object VMware.Vim.OptionValue
                $e.key = "guestinfo.dns"
                $e.value = $VMDNS.IPAddressToString
                $f = New-Object VMware.Vim.OptionValue
                $f.key = "guestinfo.domain"
                $f.value = $VMDomain
                $g = New-Object VMware.Vim.OptionValue
                $g.key = "guestinfo.ntp"
                $g.value = $VMNTP
                $h = New-Object VMware.Vim.OptionValue
                $h.key = "guestinfo.syslog"
                $h.value = $VMSyslog
                $i = New-Object VMware.Vim.OptionValue
                $i.key = "guestinfo.password"
                $i.value = $VMPassword
                $j = New-Object VMware.Vim.OptionValue
                $j.key = "guestinfo.ssh"
                $j.value = $VMSSH.ToBool()
                $k = New-Object VMware.Vim.OptionValue
                $k.key = "guestinfo.createvmfs"
                $k.value = $VMVMFS.ToBool()
                $l = New-Object VMware.Vim.OptionValue
                $l.key = "ethernet1.filter4.name"
                $l.value = "dvfilter-maclearn"
                $m = New-Object VMware.Vim.OptionValue
                $m.key = "ethernet1.filter4.onFailure"
                $m.value = "failOpen"
                $orignalExtraConfig+=$a
                $orignalExtraConfig+=$b
                $orignalExtraConfig+=$c
                $orignalExtraConfig+=$d
                $orignalExtraConfig+=$e
                $orignalExtraConfig+=$f
                $orignalExtraConfig+=$g
                $orignalExtraConfig+=$h
                $orignalExtraConfig+=$i
                $orignalExtraConfig+=$j
                $orignalExtraConfig+=$k
                $orignalExtraConfig+=$l
                $orignalExtraConfig+=$m

                $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
                $spec.ExtraConfig = $orignalExtraConfig

                My-Logger "Adding guestinfo customization properties to $vmname ..."
                $task = $vm.ExtensionData.ReconfigVM_Task($spec)
                $task1 = Get-Task -Id ("Task-$($task.value)")
                $task1 | Wait-Task | Out-Null

                My-Logger "Powering On $vmname ..."
                Start-VM -Server $viConnection -VM $vm -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            }
        } else {
            $NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
                $VMName = $_.Key
                $VMIPAddress = $_.Value

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
                $ovfconfig.common.guestinfo.ssh.value = $VMSSH.ToBool()
                $ovfconfig.common.guestinfo.createvmfs.value = $VMVMFS.ToBool()

                My-Logger "Deploying Nested ESXi VM $VMName ..."
                $vm = Import-VApp -Source $NestedESXiApplianceOVA -OvfConfiguration $ovfconfig -Name $VMName -Location $cluster -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin

                # Add the dvfilter settings to the exisiting ethernet1 (not part of ova template)
                My-Logger "Correcting missing dvFilter settings for Eth1 ..."
                $vm | New-AdvancedSetting -name "ethernet1.filter4.name" -value "dvfilter-maclearn" -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                $vm | New-AdvancedSetting -Name "ethernet1.filter4.onFailure" -value "failOpen" -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                if($bDeployNSX) {
                    My-Logger "Connecting Eth1 to $privateNetwork ..."
                    $vm | Get-NetworkAdapter -Name "Network adapter 2" | Set-NetworkAdapter -Portgroup $privateNetwork -confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
                }

                My-Logger "Updating vCPU Count to $NestedESXivCPU & vMEM to $NestedESXivMemGB GB ..."
                Set-VM -Server $viConnection -VM $vm -NumCpu $NestedESXivCPU -MemoryGB $NestedESXivMemGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                My-Logger "Updating vSAN Caching VMDK size to $NestedESXiCachingvDiskGB GB ..."
                Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 2" | Set-HardDisk -CapacityGB $NestedESXiCachingvDiskGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                My-Logger "Updating vSAN Capacity VMDK size to $NestedESXiCapacityvDiskGB GB ..."
                Get-HardDisk -Server $viConnection -VM $vm -Name "Hard disk 3" | Set-HardDisk -CapacityGB $NestedESXiCapacityvDiskGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                My-Logger "Powering On $vmname ..."
                $vm | Start-Vm -RunAsync | Out-Null
            }
        }
    }

    if($bDeployNSX) {
        if($DeploymentTarget -eq "vCenter") {
            $ovfconfig = Get-OvfConfiguration $NSXOVA
            $ovfconfig.NetworkMapping.VSMgmt.value = $VMNetwork

            $ovfconfig.common.vsm_hostname.value = $NSXHostname
            $ovfconfig.common.vsm_ip_0.value = $NSXIPAddress.IPAddressToString
            $ovfconfig.common.vsm_netmask_0.value = $NSXNetmask.IPAddressToString
            $ovfconfig.common.vsm_gateway_0.value = $NSXGateway.IPAddressToString
            $ovfconfig.common.vsm_dns1_0.value = $VMDNS.IPAddressToString
            $ovfconfig.common.vsm_domain_0.value = $VMDomain
            $ovfconfig.common.vsm_isSSHEnabled.value = $NSXSSHEnable.ToBool()
            $ovfconfig.common.vsm_isCEIPEnabled.value = $NSXCEIPEnable.ToBool()
            $ovfconfig.common.vsm_cli_passwd_0.value = $NSXUIPassword
            $ovfconfig.common.vsm_cli_en_passwd_0.value = $NSXCLIPassword

            My-Logger "Deploying NSX VM $NSXDisplayName ..."
            $vm = Import-VApp -Source $NSXOVA -OvfConfiguration $ovfconfig -Name $NSXDisplayName -Location $cluster -VMHost $vmhost -Datastore $datastore -DiskStorageFormat thin

            My-Logger "Updating vCPU Count to $NSXvCPU & vMEM to $NSXvMemGB GB ..."
            Set-VM -Server $viConnection -VM $vm -NumCpu $NSXvCPU -MemoryGB $NSXvMemGB -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

            My-Logger "Powering On $NSXDisplayName ..."
            $vm | Start-Vm -RunAsync | Out-Null
        }
    }

    if($bUpgradeESXiTo65a) {
        $NestedESXiHostnameToIPs.GetEnumerator() | sort -Property Value | Foreach-Object {
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
        }
    }

    if($deployVCSA -eq 1) {
        if($DeploymentTarget -eq "ESXI") {
            # Deploy using the VCSA CLI Installer
            $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\embedded_vCSA_on_ESXi.json") | ConvertFrom-Json
            $config.'new.vcsa'.esxi.hostname = $VIServer
            $config.'new.vcsa'.esxi.username = $Credential.UserName
            $config.'new.vcsa'.esxi.password = $Credential.GetNetworkCredential().Password
            $config.'new.vcsa'.esxi.'deployment.network' = $VMNetwork
            $config.'new.vcsa'.esxi.datastore = $datastore
            $config.'new.vcsa'.appliance.'thin.disk.mode' = $true
            $config.'new.vcsa'.appliance.'deployment.option' = $VCSADeploymentSize
            $config.'new.vcsa'.appliance.name = $VCSADisplayName
            $config.'new.vcsa'.network.'ip.family' = "ipv4"
            $config.'new.vcsa'.network.mode = "static"
            $config.'new.vcsa'.network.ip = $VCSAIPAddress.IPAddressToString
            $config.'new.vcsa'.network.'dns.servers'[0] = $VMDNS.IPAddressToString
            $config.'new.vcsa'.network.prefix = $VCSAPrefix
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
            Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula --acknowledge-ceip $($ENV:Temp)\jsontemplate.json"| Out-File -Append -LiteralPath $verboseLogFile
        } else {
            $config = (Get-Content -Raw "$($VCSAInstallerPath)\vcsa-cli-installer\templates\install\embedded_vCSA_on_VC.json") | ConvertFrom-Json
            $config.'new.vcsa'.vc.hostname = $VIServer
            $config.'new.vcsa'.vc.username = $Credential.UserName
            $config.'new.vcsa'.vc.password = $Credential.GetNetworkCredential().Password
            $config.'new.vcsa'.vc.'deployment.network' = $VMNetwork
            $config.'new.vcsa'.vc.datastore = $datastore
            $config.'new.vcsa'.vc.datacenter = $datacenter.name
            $config.'new.vcsa'.vc.target = $VMCluster
            $config.'new.vcsa'.appliance.'thin.disk.mode' = $true
            $config.'new.vcsa'.appliance.'deployment.option' = $VCSADeploymentSize
            $config.'new.vcsa'.appliance.name = $VCSADisplayName
            $config.'new.vcsa'.network.'ip.family' = "ipv4"
            $config.'new.vcsa'.network.mode = "static"
            $config.'new.vcsa'.network.ip = $VCSAIPAddress.IPAddressToString
            $config.'new.vcsa'.network.'dns.servers'[0] = $VMDNS.IPAddressToString
            $config.'new.vcsa'.network.prefix = $VCSAPrefix
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
            Invoke-Expression "$($VCSAInstallerPath)\vcsa-cli-installer\win32\vcsa-deploy.exe install --no-esx-ssl-verify --accept-eula --acknowledge-ceip $($ENV:Temp)\jsontemplate.json"| Out-File -Append -LiteralPath $verboseLogFile
        }
    }

    if($moveVMsIntovApp -eq 1 -and $DeploymentTarget -eq "vCenter") {
        My-Logger "Creating vApp $VAppName ..."
        $VApp = New-VApp -Name $VAppName -Server $viConnection -Location $cluster

        if($deployNestedESXiVMs -eq 1) {
            My-Logger "Moving Nested ESXi VMs into $VAppName vApp ..."
            $NestedESXiHostnameToIPs.GetEnumerator() | Sort-Object -Property Value | Foreach-Object {
                $vm = Get-VM -Name $_.Key -Server $viConnection
                Move-VM -VM $vm -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            }
        }

        if($deployVCSA -eq 1) {
            $vcsaVM = Get-VM -Name $VCSADisplayName -Server $viConnection
            My-Logger "Moving $VCSADisplayName into $VAppName vApp ..."
            Move-VM -VM $vcsaVM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        }

        if($bDeployNSX) {
            $nsxVM = Get-VM -Name $NSXDisplayName -Server $viConnection
            My-Logger "Moving $NSXDisplayName into $VAppName vApp ..."
            Move-VM -VM $nsxVM -Server $viConnection -Destination $VApp -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
        }
    }

    My-Logger "Disconnecting from $VIServer ..."
    Disconnect-VIServer $viConnection -Confirm:$false


    if($setupNewVC -eq 1) {
        My-Logger "Connecting to the new VCSA ..."
        $vc = Connect-VIServer $VCSAIPAddress.IPAddressToString -User "administrator@$VCSASSODomainName" -Password $VCSASSOPassword -WarningAction SilentlyContinue

        My-Logger "Creating Datacenter $NewVCDatacenterName ..."
        New-Datacenter -Server $vc -Name $NewVCDatacenterName -Location (Get-Folder -Type Datacenter -Server $vc) | Out-File -Append -LiteralPath $verboseLogFile

        My-Logger "Creating VSAN Cluster $NewVCVSANClusterName ..."
        New-Cluster -Server $vc -Name $NewVCVSANClusterName -Location (Get-Datacenter -Name $NewVCDatacenterName -Server $vc) -DrsEnabled -VsanEnabled -VsanDiskClaimMode 'Manual' | Out-File -Append -LiteralPath $verboseLogFile

        if($addESXiHostsToVC -eq 1) {
            $NestedESXiHostnameToIPs.GetEnumerator() | sort -Property Value | Foreach-Object {
                $VMName = $_.Key
                $VMIPAddress = $_.Value

                $targetVMHost = if ($AddHostByDnsName) {$VMName} else {$VMIPAddress}

                My-Logger "Adding ESXi host $targetVMHost to Cluster ..."
                Add-VMHost -Server $vc -Location (Get-Cluster -Name $NewVCVSANClusterName) -User "root" -Password $VMPassword -Name $targetVMHost -Force | Out-File -Append -LiteralPath $verboseLogFile
            }
        }

        if($bDeployNSX -and $setupVXLAN -eq 1) {
            My-Logger "Creating VDS $VDSName ..."
            $vds = New-VDSwitch -Server $vc -Name $VDSName -Location (Get-Datacenter -Name $NewVCDatacenterName)

            My-Logger "Creating new VXLAN DVPortgroup $VXLANDVPortgroup ..."
            $vxlanDVPG = New-VDPortgroup -Server $vc -Name $VXLANDVPortgroup -Vds $vds

            $vmhosts = Get-Cluster -Server $vc -Name $NewVCVSANClusterName | Get-VMHost
            foreach ($vmhost in $vmhosts) {
                $vmhostname = $vmhost.name

                My-Logger "Adding $vmhostname to VDS ..."
                Add-VDSwitchVMHost -Server $vc -VDSwitch $vds -VMHost $vmhost | Out-File -Append -LiteralPath $verboseLogFile

                My-Logger "Adding vmmnic1 to VDS ..."
                $vmnic = $vmhost | Get-VMHostNetworkAdapter -Physical -Name vmnic1
                Add-VDSwitchPhysicalNetworkAdapter -Server $vc -DistributedSwitch $vds -VMHostPhysicalNic $vmnic -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile

                $vmk0 = Get-VMHostNetworkAdapter -Server $vc -Name vmk0 -VMHost $vmhost
                $lastNetworkOcet = $vmk0.ip.Split('.')[-1]
                ## make the new VMKernel portgroup IP from the first three octects of the given Subnet address and the last octet of this VMHost's management IP address
                $vxlanVmkIP = ($VXLANSubnet.IPAddressToString.Split(".")[0..2],$lastNetworkOcet | Foreach-Object {$_}) -join "."

                My-Logger "Adding VXLAN VMKernel $vxlanVmkIP to VDS ..."
                New-VMHostNetworkAdapter -VMHost $vmhost -PortGroup $VXLANDVPortgroup -VirtualSwitch $vds -IP $vxlanVmkIP -SubnetMask $VXLANNetmask.IPAddressToString -Mtu 1600 | Out-File -Append -LiteralPath $verboseLogFile
           }
        }

        if($configureVSANDiskGroups -eq 1) {
            My-Logger "Enabling VSAN Space Efficiency/De-Dupe & disabling VSAN Health Check ..."
            Get-VsanClusterConfiguration -Server $vc -Cluster $NewVCVSANClusterName | Set-VsanClusterConfiguration -SpaceEfficiencyEnabled $true -HealthCheckIntervalMinutes 0 | Out-File -Append -LiteralPath $verboseLogFile


            foreach ($vmhost in Get-Cluster -Server $vc | Get-VMHost) {
                $luns = $vmhost | Get-ScsiLun | select CanonicalName, CapacityGB

                My-Logger "Querying ESXi host disks to create VSAN Diskgroups ..."
                foreach ($lun in $luns) {
                    if(([int]($lun.CapacityGB)).toString() -eq "$NestedESXiCachingvDiskGB") {
                        $vsanCacheDisk = $lun.CanonicalName
                    }
                    if(([int]($lun.CapacityGB)).toString() -eq "$NestedESXiCapacityvDiskGB") {
                        $vsanCapacityDisk = $lun.CanonicalName
                    }
                }
                My-Logger "Creating VSAN DiskGroup for $vmhost ..."
                New-VsanDiskGroup -Server $vc -VMHost $vmhost -SsdCanonicalName $vsanCacheDisk -DataDiskCanonicalName $vsanCapacityDisk | Out-File -Append -LiteralPath $verboseLogFile
              }
        }

        if($clearVSANHealthCheckAlarm -eq 1) {
            My-Logger "Clearing default VSAN Health Check Alarms, not applicable in Nested ESXi env ..."
            $alarmMgr = Get-View AlarmManager -Server $vc
            Get-Cluster -Server $vc | where {$_.ExtensionData.TriggeredAlarmState} | %{
                $cluster = $_
                $Cluster.ExtensionData.TriggeredAlarmState | %{
                    $alarmMgr.AcknowledgeAlarm($_.Alarm,$cluster.ExtensionData.MoRef)
                }
            }
        }

        # Exit maintanence mode in case patching was done earlier
        foreach ($vmhost in Get-Cluster -Server $vc | Get-VMHost) {
            if($vmhost.ConnectionState -eq "Maintenance") {
                Set-VMHost -VMhost $vmhost -State Connected -RunAsync -Confirm:$false | Out-File -Append -LiteralPath $verboseLogFile
            }
        }

        My-Logger "Disconnecting from new VCSA ..."
        Disconnect-VIServer $vc -Confirm:$false
    }

    if($configureNSX -eq 1 -and $bDeployNSX -and $setupVXLAN -eq 1) {
        if(!(Connect-NSXServer -Server $NSXHostname -Username admin -Password $NSXUIPassword -DisableVIAutoConnect -WarningAction SilentlyContinue)) {
            Write-Host -ForegroundColor Red "Unable to connect to NSX Manager, please check the deployment"
            exit
        } else {
            My-Logger "Successfully logged into NSX Manager $NSXHostname ..."
        }

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
    My-Logger "StartTime: $StartTime"
    My-Logger "  EndTime: $EndTime"
    My-Logger " Duration: $duration minutes"
}