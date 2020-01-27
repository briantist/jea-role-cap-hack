
<#PSScriptInfo

.VERSION 1.0

.GUID aa740796-8b48-4b9f-bb1c-efc4875f5406

.AUTHOR Brian Scholer

.COMPANYNAME

.COPYRIGHT Brian Scholer

.TAGS JEA RoleCapability JustEnoughAdministration

.LICENSEURI https://github.com/briantist/jea-role-cap-hack/blob/master/LICENSE

.PROJECTURI https://github.com/briantist/jea-role-cap-hack

.ICONURI

.EXTERNALMODULEDEPENDENCIES

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES
 - 1.0: Initial Release


.PRIVATEDATA

#>

<#

.DESCRIPTION
 Hacks around JEAs unawareness of versioned modules
 See also: https://github.com/PowerShell/PowerShell/issues/4105

 Runs as an infinite loop monitoring the filesystem unless used
 with the -NoMonitor parameter.

#>
[CmdletBinding()]
Param(
    [Parameter()]
    [String]
    [ValidateNotNullOrEmpty()]
    $ModulePathEnvironmentVariable = 'PSModulePath' ,

    [Parameter()]
    [UInt32]
    $EventIntervalSeconds = 10 ,

    [Parameter()]
    [Switch]
    $NoMonitor
)

function New-Watcher {
    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory,
            ValueFromPipeline
        )]
        [ValidateNotNullOrEmpty()]
        [System.IO.DirectoryInfo]
        $Path ,

        [Parameter(
            Mandatory
        )]
        [ScriptBlock]
        $Action
    )

    Process {
        Write-Verbose -Message "Adding watcher for path '$($Path.FullName)'."

        $FileSystemWatcher = [System.IO.FileSystemWatcher]::new($Path.FullName)
        $FileSystemWatcher.IncludeSubdirectories = $true

        $EventHandlers = foreach($EventName in 'Created','Deleted','Renamed') { # Changed is too noisy, not needed for this
            Register-ObjectEvent -InputObject $FileSystemWatcher -EventName $EventName -Action $Action -MessageData $Path
        }

        $FileSystemWatcher.EnableRaisingEvents = $true

        New-Object -TypeName PSObject -Property @{
            Path = $FileSystemWatcher.Path
            PathInfo = $Path
            Watcher = $FileSystemWatcher
            Handlers = $EventHandlers
        }
    }
}

function Remove-Watcher {
    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory,
            ValueFromPipeline
        )]
        [ValidateNotNullOrEmpty()]
        [PSObject]
        $WatcherInfo
    )

    Process {
        Write-Verbose -Message "Removing watcher for path '$($WatcherInfo.Path)'."

        foreach ($handler in $WatcherInfo.Handlers) {
            Unregister-Event -SubscriptionId $handler.Id -Force
            Remove-Job -Id $handler.Id -Force
        }

        $WatcherInfo.Watcher.EnableRaisingEvents = $false
        $WatcherInfo.Watcher.Dispose()
    }
}

$ActionHandler = {
    param(
        $ManualPath  # Manually passed path, didn't come from event
    )
    # $Info = $Event.SourceEventArgs
    # $Name = $Info.Name
    # $FullPath = $Info.FullPath | Get-Item
    # $OldFullPath = $Info.OldFullPath
    # $OldName = $Info.OldName
    # $ChangeType = $Info.ChangeType
    # $Timestamp = $Event.TimeGenerated

    $ModPath = if ($Event) {
        $Event.MessageData
    } else {
        $ManualPath
    }
    $roleCap = 'RoleCapabilities'

    # let's not to try actually figure out what happened in this event
    # instead we'll just process the entire module directory 😬
    Write-Verbose -Message "Enumerating path '$($ModPath.FullName)':"
    foreach ($module in $ModPath.EnumerateDirectories()) {
        if(@(
             '{0}.psm1' -f $module.BaseName
            ,'{0}.psd1' -f $module.BaseName
            ,'DSCResources'
            ,'PSGetModuleInfo.xml'
        ).Where({ $module.FullName | Join-Path -ChildPath $_ | Test-Path })) {
            # this is a regular module directory (probably)
            Write-Verbose -Message "-- Skipping '$module' because it seems like like a regular module."
            continue
        }

        $latest = $module.EnumerateDirectories() |
            Where-Object -FilterScript { $_.BaseName -as [System.Version] } |
            Sort-Object -Property { $_.BaseName -as [System.Version] } -Descending |
            Select-Object -First 1

        Write-Verbose -Message "-- Latest version of '$module' seems to be '$latest'"

        $latestRoles = ($latest.FullName | Join-Path -ChildPath $roleCap) -as [System.IO.DirectoryInfo]
        Write-Verbose -Message "-- Looking for latest roles in '$($latestRoles.FullName)'."
        if ($latestRoles.Exists) {
            Write-Verbose -Message "---- found!"
        }

        $upperLevelRoles = ($module.FullName | Join-Path -ChildPath $roleCap) -as [System.IO.DirectoryInfo]
        if ($upperLevelRoles.Exists) {
            $upperLevelRoles = $upperLevelRoles | Get-Item
            if (
                $upperLevelRoles.LinkType -and
                $upperLevelRoles.LinkType -eq 'SymbolicLink' -and
                $upperLevelRoles.Target.Count -eq 1 -and (
                    -not $latestRoles.Exists -or (
                        $upperLevelRoles.Target[0].TrimEnd([System.IO.Path]::DirectorySeparatorChar) -ne
                        $latestRoles.FullName.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
                    )
                )) {
                # delete a symlinked role cap folder if the latest module doesn't have one
                # or if it does and the symlink doesn't point there
                $upperLevelRoles.Delete()
            } else {
                # tf exists but we didn't delete it, so pass
                Write-Verbose -Message "-- '$($upperLevelRoles.FullName)' exists but won't be deleted or overwritten; skipping."
                continue
            }
        }

        if ($latestRoles.Exists) {
            # create the symlink pointing into the latest modules role caps
            Write-Verbose -Message ("-- Creating symlink from '{0}' to '{1}'." -f $upperLevelRoles.FullName, $latestRoles.FullName)
            $null = New-Item -Path $upperLevelRoles.FullName -Value $latestRoles.FullName -ItemType SymbolicLink -Force
        }
    }
}

try {
    $watchers = @{}

    # forever loop
    for() {
        $paths = [System.Environment]::GetEnvironmentVariable(
            $ModulePathEnvironmentVariable,
            [System.EnvironmentVariableTarget]::Machine
        ).Split([System.IO.Path]::PathSeparator) -as [System.IO.DirectoryInfo[]]

        $keys = $watchers.Keys | Out-String -Stream
        foreach ($key in $keys) {
            if ($key -notin $paths.FullName) {
                Remove-Watcher -WatcherInfo $watchers[$key]
                $watchers.Remove($key)
            }
        }

        foreach ($path in $paths) {
            if ($path.FullName -notin $keys) {
                if ($Path.Exists) {
                    # call the action on the path once so that we don't wait for a change to process what's already in there
                    Invoke-Command -ScriptBlock $ActionHandler -ArgumentList $path

                    if ($NoMonitor) {
                        # don't add a watcher if we're just doing this as a one-time thing
                        continue
                    }

                    $watchers[$path.FullName] = New-Watcher -Path $path -Action $ActionHandler
                } else {
                    Write-Verbose -Message "Skipping path '$($Path.FullName)' because it doesn't exist or is not a directory."
                }
            }
        }

        if ($NoMonitor) {
            # exit the loop if we're not using watchers
            break
        }

        Wait-Event -Timeout $EventIntervalSeconds
    }
} finally {
    # kill the event handlers
    Get-EventSubscriber -Force | Unregister-Event -Force
}
