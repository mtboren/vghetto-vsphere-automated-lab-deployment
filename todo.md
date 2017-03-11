### ToDo items, and done items

#### ToDo:
- address starting of patching of vESXi before vESXi hosts are ready: add a check for "target vESXi host is responsive to API requests" kind of thing before starting `Install-VMHostPatch` on said host
- optimize/standardize code
  - do `Install-VMHostPatch` in parallel (via `-RunAsync`, then use `Wait-Task`)
  - update PowerShell aliases with full command names
  - replace `Write-Host -ForegroundColor Red` with `Write-Error -Message`
  - maybe: consolidate (function-ize) code that gets VMHost SCSI LUNs for `vsanCacheDisk` and `vsanCapacityDisk`, for configuring VSAN (similar code used in two spots right now)
- add NTP server config in VCSA deployment (not currently setting the parameter in JSON template for VCSA deploy)
- update layout of sample .json files to have a bit of logical separation/grouping for params
- add summary table of things like timespans for each section, resources that were created and where, etc., for easy visibility at end of deployment run (potentially via a hashtable that is built along the way)


#### Done:
- selected main script on which to base new, main script:  `vsphere-6.5-vghetto-standard-lab-deployment.ps1`
- parameterized new script called `New-vGhetto_vSphereLab.ps1` that will [eventually] support all functions of the four original scripts
	- specify mandatory where approprate, parameter types, validation, etc.
	- ensure that code expects given types, not just strings for each param
- added example input parameters JSON file, with generic values
- added tidbit to detect `DeploymentTarget`, instead of requiring user specify (can determine from `$global:DefaultVIServer.ExtensionData.Content.About.ApiType`)
- added logging entries for how long each of several import/deployment/configuration sections took along the way
- updated VSS/VDS support to not require user to specify vSwitch type (pertinent code will just `try {Get-VDPortgroup ...}`, and in catch, do `Get-VirtualPortgroup`)
	- handled this by updating code to not rely on following (when parameterizing code, did not include this as a param):
``` PowerShell
	# General Deployment Configuration for Nested ESXi, VCSA & NSX VMs
	$VirtualSwitchType = "VDS" # VSS or VDS
```
- added support for `DatastoreCluster` as deployment destination (for param `-VMDatastore`)
- added tidbit that could report the "disk progress" on the VCSA import, for the consumer's info (via `Tee-Object`); not in use
- optimize/standardize
	- replaced `$VIUsername`, `$VIPassword` with a PSCredential object, so that people need not pass any password in the clear
	- removed `Test-Path` items in "precheck" section, as parameter validation now handles that check
	- updated section that does configuration of VSAN disks to use `New-VsanDiskGroup` asynchronously, so that this can be done in parallel on all of the new vESXi hosts created for the lab (potentially saving a few minutes or more -- saved ~3.5 minutes in testing a three-host deploy)
	- updated date/time format in logging function to generate a non-ambiguous, reconsumable datetime string (resulting string can be used to get a DateTime object via `Get-Date`, say, if someone was wanting to do some interesting analysis of the log using, of course, PowerShell)
	- use more robust types versus strings only (like, use `int` values for CPU/mem/disk, `boolean` values where applicable, `PSCredential` objects instead of passwords in the clear, etc.), to be able to take advantage of the associated benefits (math, equality comparison, logic flow, security, etc.)
	- updated `My-Logger` function to have Verb-Noun name, `Write-MyLogger`, to take log file parameter (instead of using global-scope parameters), and added a DefaultParameter for the new parameter for all calls, so as not to have to specify the logfile name at every invocation (See `about_Parameters_Default_Values` for lots of info about `$PSDefaultParameterValues`)- encapsulated some output-generating code into function-based snippet `_Write-ConfigMessageToHost` (vs. hundreds of explicit `Write-Host` lines), for consistency of output, ease of maintenance, etc.
	- variable-ized the logging date/time format string, so that it is set in a single spot and used consistently throughout
- replaced having default-values for some/many parameters with having example configurations in JSON, for better parameter checking / validation (default parameter values do not get validated)
- added support for specifying multiple DNS server IPs for new VMs' guest OS network configurations (via `-VMDNS` parameter)
	- current ESXi templates seem to only support single DNS server via OVF config (tested as array, and as comma-separated values -- no avail), so only the first DNS server address provided is passed on to config for new vESXi hosts
- consolidated two separate-but-similar .ps1 scripts into a PowerShell Advanced Function (see `about_Functions_Advanced`), which allows for same configuration options (vSphere 6.0 / 6.5, standalone), but via parameters (which can be stored in JSON and passed via pipeline)
	- eventually just one script instead of four (4) sets of similar code to have to maintain (reduce code redundancy); currently consolidated two of the four as `New-vGhetto_vSphereLab.ps1` (consolidated  `vsphere-6.0-vghetto-standard-lab-deployment.ps1` and `vsphere-6.5-vghetto-standard-lab-deployment.ps1`)
	- for ease of consumption by user
	- with built-in help, so that `Get-Help -full New-vGvSphereLab` gives PowerShell help like any legit cmdlet / advanced function
	- observed differences handled between 6.0- and 6.5 "standard" deployment scripts:
		- VCSA config property key names -- they differ between 6.0 and 6.5 (already handled key name difference between deployment target of ESXi and vCenter in 6.5)
			- needed to auto-determine vSphere version -- done so by using version information on the VCSA install media (`<iso>\vcsa\version.txt` and/or `<iso>\readme.txt`)
		- only employ `Set-VsanClusterConfiguration` if vSphere version is 6.0u3 or higher (which includes 6.5 and up)
		- if deployment vSphere version is 6.0, disregard `ESXi65aOfflineBundle` parameter (not pertinent to such deploy)
- rolling "self-managed" functionality into `New-vGhetto_vSphereLab.ps1` (not adding NSX support at first); have completed:
  - for vESXi sizing, use max of specified and some set of "min self-managed sizes", so that there will be resources on the vESXi hosts (mem, disk); warns user if sizes to be used are larger than those that the user specified
  - connect to one vESXi host and create VSAN cluster, config disks, disconnect from vESXi
  - for the VCSA deploy, in VCSA config JSON, specify vESXi for hostname, "root" for username, proper vESXi password, and static VM vPG and datastore names (instead of values that would be used for "standard" deploy)
  - for VSAN config in `configureVSANDiskGroups` section and for when deployment type is self-managed, added logic to only do config if `Get-VsanDiskGroup` for given VMHost is `$null`, so as to act only on remaining vESXi hosts (the ones aside from "bootstrap" host) that do not already have their VSAN diskgroup
  - added tidbit for self-managed deploment to set "VSAN default VM Storage Policy back to its defaults" via `Get-SpbmStoragePolicy`
  - added logic to handle if NSX ParameterSet is used but the deploy type is self-managed: writes warning that tool does not yet support NSX-on-self-managed deployments, prepares deploy _without_ NSX components


#### Notes
- for the "self-managed" deployment functionality in `New-vGhetto_vSphereLab.ps1`, not adding "deploy NSX, too" support at first. For initial integration of the self-managed functionality/layout, a "self-managed" deploy will cause NSX to not be deployed (even if NSX-specific ParameterSet is used; writes warning in such an event)


#### Tests to run (write some actual Pester tests?):
- for vSphere 6.0 and 6.5:
  - with and without NSX
	  - both as standard and `-DeployAsSelfManaged`
	  	- deploy to ESXi and to vCenter
