ToDo:
- address starting of patching of vESXi before vESXi hosts are ready: add a check for "target vESXi host is responsive to API requests" kind of thing before starting `Install-VMHostPatch` on said host
- optimize/standardize code
	- do `Install-VMHostPatch` in parallel (via `-RunAsync`, then use `Wait-Task`)
	- update PowerShell aliases with full command names
	- replace `Write-Host -ForegroundColor Red` with `Write-Error -Message`
	- update `My-Logger` function to have Verb-Noun name, take log file parameter (instead of using global-scope parameters) and have a DefaultParameter for that parameter for all calls, so as not to have to specify the logfile name at every invocation
- add support for `DatastoreCluster` as deployment destination


Done:
- selected main script on which to base new, main script:  `vsphere-6.5-vghetto-standard-lab-deployment.ps1`
- parameterized script
	- specify mandatory where approprate, parameter types, validation, etc.
	- ensure that code expects given types, not just strings for each param
- added example input parameters JSON file, with generic values
- added tidbit to detect `DeploymentTarget`, instead of requiring user specify (can determine from `$global:DefaultVIServer.ExtensionData.Content.About.ApiType`)
- added logging entries for how long each VM import/deployment took along the way
- updated VSS/VDS support to not require user to specify vSwitch type (pertinent code will just `try {Get-VDPortgroup ...}`, and in catch, do `Get-VirtualPortgroup`)
	- handled this by updating code to not rely on following (when parameterizing code, did not include this as a param):
``` PowerShell
	# General Deployment Configuration for Nested ESXi, VCSA & NSX VMs
	$VirtualSwitchType = "VDS" # VSS or VDS
```
- added tidbit that could report the "disk progress" on the VCSA import, for the consumer's info (via `Tee-Object`); not in use
- optimize/standardize
	- replaced `$VIUsername`, `$VIPassword` with a PSCredential object, so that people need not pass any password in the clear
	- removed `Test-Path` items in "precheck" section, as parameter validation now handles that check
	- updated section that does configuration of VSAN disks to use `New-VsanDiskGroup` asynchronously, so that this can be done in parallel on all of the new vESXi hosts created for the lab (potentially saving a few minutes or more -- saved ~3.5 minutes in testing a three-host deploy)
	- updated date/time format in logging function to generate a non-ambiguous, reconsumable datetime string (resulting string can be used to get a DateTime object via `Get-Date`, say, if someone was wanting to do some interesting analysis of the log using, of course, PowerShell)
	- use more robust types versus strings only (like, use `int` values for CPU/mem/disk, `boolean` values where applicable, `PSCredential` objects instead of passwords in the clear, etc.), to be able to take advantage of the associated benefits (math, equality comparison, logic flow, security, etc.)
- encapsulated some output-generating code into function-based snippet `_Write-ConfigMessageToHost` (vs. hundreds of explicit `Write-Host` lines), for consistency of output, ease of maintenance, etc.
- replaced having default-values for some/many parameters with having example configurations in JSON, for better parameter checking / validation (default parameter values do not get validated)
- add support for specifying multiple DNS server IPs for new VMs' guest OS network configurations (via `-VMDNS` parameter)
	- ESXi template seems to only support single DNS server via OVF config (tested as array, and as comma-separated values -- no avail, at least w/ 6.0 OVA)
- consolidated two separate-but-similar .ps1 scripts into a PowerShell Advanced Function (see `about_Functions_Advanced`), which allows for same configuration options (vSphere 6.0 / 6.5, standalone), but via parameters (which can be stored in JSON and passed via pipeline)
	- eventually just one script instead of four (4) sets of similar code to have to maintain (reduce code redundancy); currently consolidated two of the four as `New-vGhetto_vSphereLab.ps1` (consolidated  `vsphere-6.0-vghetto-standard-lab-deployment.ps1` and `vsphere-6.5-vghetto-standard-lab-deployment.ps1`)
	- for ease of consumption by user
	- with built-in help, so that `Get-Help -full New-vGvSphereLab` gives PowerShell help like any legit cmdlet / advanced function
	- observed differences handled between 6.0- and 6.5 "standard" deployment scripts:
		- VCSA config property key names -- they differ between 6.0 and 6.5 (already handled key name difference between deployment target of ESXi and vCenter in 6.5)
			- needed to auto-determine vSphere version -- done so by using version information on the VCSA install media (`<iso>\vcsa\version.txt` and/or `<iso>\readme.txt`)
		- only employ `Set-VsanClusterConfiguration` if vSphere version is 6.0u3 or higher (which includes 6.5 and up)
		- if deployment vSphere version is 6.0, disregard `ESXi65aOfflineBundle` parameter (not pertinent to such deploy)
