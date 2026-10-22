@{
    Schema = 'simrig.rule/1'
    Area   = 'services-tasks'
    Rules  = @(
        @{
            Id                = 'ST-SERVICES'
            PublicDetail      = 'Background Windows services that can wake up mid-race and take CPU or disk. This row checks each one against the state the session expects.'
            Order             = 50
            Name              = 'Service states'
            Kind              = 'Service'
            Source            = 'SCM'
            ValueKey          = 'Services'
            Expected          = $null
            Severity          = 'Fail'
            AppliesTo         = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional       = $false
            ProvisionalReason = $null
            Detail            = $null
            Reason            = 'Every quiet-list service must read back at its known-good ENABLED start type before the quiet step runs (flag 5). A service already sitting at its quiet target means something disabled it outside v4 and it never got restored.'
            Evidence          = 'OPUS-BUILD-BRIEF-v4-2026-09-19.md flag 5; CONTRACT.md "flag 5" comment above Get-PreflightCheck in engine/Engine.Preflight.ps1.'
        }
        @{
            Id                = 'ST-TASKS'
            PublicDetail      = 'Scheduled tasks that can start during a race - update scans, telemetry uploads, disk maintenance. This row checks each one is in the state the session expects.'
            Order             = 60
            Name              = 'Task states'
            Kind              = 'Task'
            Source            = 'Task Scheduler'
            ValueKey          = 'Tasks'
            Expected          = $null
            Severity          = 'Fail'
            AppliesTo         = @{ Profile = 'any'; Ccd = 'any'; Gpu = 'any'; Windows = 'any' }
            Provisional       = $false
            ProvisionalReason = $null
            Detail            = $null
            Reason            = 'Every quiet-list task must read back Enabled before the quiet step runs, the same known-good-ENABLED rule as services (flag 5). A task the profile marks WindowsManaged is recorded, not graded, because Windows toggles it on its own.'
            Evidence          = 'OPUS-BUILD-BRIEF-v4-2026-09-19.md flag 5; CONTRACT.md "flag 5" comment above Get-PreflightCheck in engine/Engine.Preflight.ps1; known-good.psd1 Tasks WindowsManaged entries.'
        }
    )
}
