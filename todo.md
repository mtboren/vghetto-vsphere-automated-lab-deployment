ToDo:
- parameterize script
	- specify mandatory where approprate, parameter types, validation, etc.
	- ensure that code expects given types, not just strings for each param
- update creation of ESXi VMs to do single Import, rest as clones (if deployment target is ESXi)?
- add logging entries for how long each VM import/deployment took
- update VSS/VDS support to not require user to specify vSwitch type (just try Get-VirtualPortgroup, and in catch, do Get-VDPortGroup)
	- handle this by updating code to not rely on following (when parameterizing code, did not include this as a param):
``` PowerShell
	# General Deployment Configuration for Nested ESXi, VCSA & NSX VMs
	$VirtualSwitchType = "VDS" # VSS or VDS
```
- add support for `ShouldProcess()` (replacing confirmation with standard PowerShell `-WhatIf` support)
- optimize/standardize
	- update PowerShell aliases with full command names
	- replace `Write-Host -ForegroundColor Red` with `Write-Error -Message`
	- updaet `My-Logger` function to have Verb-Noun name, take log file parameter (instead of using global-scope parameters) and have a DefaultParameter for that parameter for all calls, so as not to have to specify the logfile name at every invocation
	- replaced `$VIUsername`, `$VIPassword` with a PSCredential object, so that people need not pass any password in the clear
	- removed `Test-Path` items in "precheck" section, as parameter validation now handles that check
- integrate other scripts' functionality into updated script

Done:
- selected main script on which to base new, main script:  `vsphere-6.5-vghetto-standard-lab-deployment.ps1`
- added example input parameters JSON file, with generic values
- detect `DeploymentTarget`, instead of requiring user specify (can determine from `$global:DefaultVIServer.ExtensionData.Content.About.ApiType`)
