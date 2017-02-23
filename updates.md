### To-do items and updates as suggested by MTBoren
- consolidate *ps1 into a PowerShell Advanced Function (see `about_Functions_Advanced`) that will allow for same configurations (vSphere 6.0 / 6.5, standalone/self-managed), but via parameters
  - instead of four (4) sets of similar code to have to maintain (reduce code redundancy)
  - for ease of consumption by user
  - with built-in help, so that `Get-Help -full New-vGvSphereLab` gives PowerShell help like any legit cmdlet / advanced function
- use more robust types versus strings only (like, use `int` values for CPU/mem/disk, `boolean` values where applicable, `PSCredential` objects instead of passwords in the clear, etc.), to be able to take advantage of the associated benefits (math, equality comparison, logic flow, security, etc.)
- replace having default-values for parameters with having example configurations in JSON, for better parameter checking / validation (default parameter values do not get validated)
- add support for `DatastoreCluster` as deployment destination
- encapsulate some output-generating code into function-based snippets (vs. hundreds of explicit `Write-Host` lines)
- add support for specifying multiple DNS server IPs for new VMs' guest OS network configurations (via `-VMDNS` parameter)
