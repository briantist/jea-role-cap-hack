# Installation
The script is packaged in the [PowerShellGallery](https://www.powershellgallery.com/packages/Repair-PowerShellGetModuleRoleCapabilities/):

```powershell
Install-Script -Name Repair-PowerShellGetModuleRoleCapabilities
```

## `Repair-PowerShellGetModuleRoleCapabilities.ps1`
Hacks a fix to JEA role capability searching in versioned PowerShell modules.

### Issue
https://github.com/PowerShell/PowerShell/issues/4105

JEA's method of discovering role capability files within modules doesn't work with versioned modules
(modules of the structure `ModuleName\1.2.3\<ModuleFiles>`).

## Workaround
This script works around the issue by checking each of the module directories in the path (`%PSModulePath%`)
and creating a symlink in the upper module folder (the named folder) for `RoleCapabilities` that points to
the `RoleCapabilities` folder inside the module's latest version.

The script checks each module if finds. If the following conditions are met:

* The module is versioned
* The module top-level does not already contain a file/folder named `RoleCapabilities`
* The module's latest version does contain a `RoleCapabilities` folder

Then a new symlink is created as described above.

If a symlink already exists, it is deleted unless its target matches what the target above would have been.

The script sets up `FileSystemWatcher`s on each folder in the module path so that it can be notified of changes and
immediately apply the above logic, which will create/repair the symlinks as needed.

There is also a timeout (defaults to `10` seconds) that re-checks the enviroment variable to see if the module paths
have changed. If it changes, watchers are added/removed as needed.

Note that the timeout only applies to re-checking the environment variable; filesystem change events get fired off
immediately so there is no delay there.

The script can aslo be invoked with `-NoMonitor` to just apply the symlinks one time, without using watchers and running
in an infinite loop. This can be used if you want to schedule the script to run at your own interval or run it one-off.

## Known Issues

* Paths are not well-sanitized or normalized. It's possible to add duplicate watchers by adding different looking paths
  to the path var even though they are the same (trailing slash, 8.3 names, etc.). This could cause issues with target
  detection in the symlink. In general, it's unlikely you'll run into path issues, but it's a possibility.
* Despite listening to the filesystem for changes, any change within a path causes that entire path to be re-scanned.
  This actually helps with the above issue because of the paths checked are enumerated rather than built. This is unlikely
  to cause a problem unless you have very frequent changes to modules.
