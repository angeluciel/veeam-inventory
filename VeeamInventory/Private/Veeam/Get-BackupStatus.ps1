function Get-BackupStatus {
    param(
        [Parameter(Mandatory)]$VMs,
        [Parameter(Mandatory)][hashtable]$Catalog,
        [int]$MaxHoursBackup = $config.MaxHoursBackup
    )

    $now = [DateTimeOffset]::UtcNow
    $result = @()

    foreach ($vmName in (@($VMs) | Select-Object -ExpandProperty VMName -Unique)) {
        $name = $vmName.Trim()
        $entry = $Catalog[$name]

        if (-not $entry) {
            $result += [PSCustomObject]@{
                VM          = $name
                HasBackup   = $false
                LastBackup  = $null
                HoursBehind = $null
                DaysBehind  = $null
                Status      = 'SEM_BACKUP'
                Message     = 'Nunca teve backup com restore point'
                Platform    = $null
                Points      = 0
                ObjectId    = $null
            }
            continue
        }

        $lastBackup = [DateTimeOffset]$entry.LastBackup
        $hours = ($now - $lastBackup.ToUniversalTime()).TotalHours
        $days = [math]::Round($hours / 24, 1)
        $isCurrent = $hours -le $MaxHoursBackup

        if ($hours -lt 0) {
            $hours = 0
        }

        $message = if ($isCurrent) {
            "Último backup há $([math]::Round($hours, 1))h"
        }
        elseif ($hours -lt 24) {
            "Sem backup há $([math]::Round($hours, 1))h"
        }
        else {
            "Sem backup há $days dias"
        }

        $result += [PSCustomObject]@{
            VM          = $name
            HasBackup   = $isCurrent
            LastBackup  = $entry.LastBackup
            HoursBehind = [math]::Round($hours, 1)
            DaysBehind  = $days
            Status      = if ($isCurrent) { 'OK' } else { 'ATRASADO' }
            Message     = $message
            Platform    = $entry.Platform
            Points      = $entry.Points
            ObjectId    = $entry.ObjectId
        }
    }

    return $result
}