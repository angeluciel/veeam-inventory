param(
    [string]$ConfigPath = (
        Join-Path $PSScriptRoot '..\config.psd1'
    ),
    [switch]$NoSave
)

$repoRoot = Split-Path $PSScriptRoot -Parent

Import-Module "$repoRoot\modules\VeeamApi\VeeamApi.psm1" -Force
Import-Module "$repoRoot\modules\PSLogging\PSLogging.psm1" -Force

#region - Importing Functions

. "$PSScriptRoot\Private\Adapter\ConvertTo-JobObject.ps1"

. "$PSScriptRoot\Private\Infra\Get-Hosts.ps1"
. "$PSScriptRoot\Private\Infra\Get-VMs.ps1"

. "$PSScriptRoot\Private\Veeam\Get-BackupStatus.ps1"
. "$PSScriptRoot\Private\Veeam\Get-ProtectedObjects.ps1"
. "$PSScriptRoot\Private\Veeam\Get-RepositoryNameFromId.ps1"
. "$PSScriptRoot\Private\Veeam\Get-VeeamJobs.ps1"
. "$PSScriptRoot\Private\Veeam\Get-VeeamRepositories.ps1"

. "$PSScriptRoot\Public\Get-BackupCatalog.ps1"
. "$PSScriptRoot\Public\Get-InventoryVMs.ps1"
. "$PSScriptRoot\Public\Send-N8nWebhook.ps1"

#endregion

function Main {
    param()

    if (-not (Test-Path $ConfigPath)) {
        throw @"
        Configuration file not found:
        $ConfigPath

        Copy config.example.psd1 to config.psd1 and configure it before running.
"@
    }

    $config = [PSCustomObject](
        Import-PowerShellDataFile -Path $ConfigPath
    )

    $requriedSettings = @(
        'VeeamBaseUrl'
        'ApiVersion'
        'PathToCredential'
    )

    foreach($setting in $requriedSettings) {
        if ([string]::IsNullOrWhiteSpace($config.$setting)) {
            throw "Required configuration value '$setting' is missing."
        }
    }

    try {
        Initialize-Logging -Directory $config.LogDirectory -RetentionDays $config.LogRetentionDays
        Initialize-VeeamApi `
            -BaseUrl $config.VeeamBaseUrl `
            -ApiVersion $config.ApiVersion `
            -MaxRetries 3 `
            -CredentialPath $config.PathToCredential

        Unlock-VeeamCredentialStore

        $token = Connect-VeeamApi

        $headers = @{
            "Authorization" = "Bearer $token"
            "accept"        = "application/json"
            "x-api-version" = $config.ApiVersion
        }

        $protectedObjects = @(Get-ProtectedObjects -headers $headers -BaseUrl $config.VeeamBaseUrl)
        $backupCatalog = Get-BackupCatalog `
            -Headers $headers `
            -Objects $protectedObjects `
	    -BaseUrl $config.VeeamBaseUrl

        $vms = @(Get-InventoryVMs `
            -Headers $headers `
            -BaseUrl $config.VeeamBaseUrl)

        $backupStatus = @(Get-BackupStatus `
            -VMs $vms `
            -Catalog $backupCatalog `
            -MaxHoursBackup $config.MaxHoursBackup)

        $vmsWithBackup = @($backupStatus | Where-Object HasBackup)
        $vmsWithoutBackup = @($backupStatus | Where-Object { -not $_.HasBackup })
        $overdueVMs = @($backupStatus | Where-Object Status -eq 'ATRASADO')

        Write-Log "`n----- Resumo de backup das VMs -----" -Level INFO -Context "RESUMO"
        Write-Log "Total avaliado : $($backupStatus.Count)" -Level INFO -Context "RESUMO"
        Write-Log "Com Backup     : $($vmsWithBackup.Count)" -Level SUCCESS -Context "RESUMO"
        Write-Log "Atrasadas      : $($overdueVMs.Count)" -Level WARN -Context "RESUMO"
        Write-Log "Sem Backup     : $($vmsWithoutBackup.Count)" -Level ERROR -Context "RESUMO"

        if ($vmsWithoutBackup.Count -gt 0) {
            Write-Log "VMs sem backup:" -Level ERROR -Context 'RESUMO'

            $vmsWithoutBackup | ForEach-Object {
                Write-Log " - $($_.VM)" -Level ERROR -Context 'RESUMO'
            }
        }

        if ($overdueVMs.Count -gt 0) {
            Write-Log "VMs sem backup há dias:" -Level WARN -Context 'RESUMO'

            $overdueVMs | ForEach-Object {
                Write-Log " - $($_.VM): $($_.Message)" -Level WARN -Context 'RESUMO'
            }
        }

        $jobs = Get-VeeamJobs -BaseUrl $config.VeeamBaseUrl -Headers $headers
        $repoMap = Get-VeeamRepositories -BaseUrl $config.VeeamBaseUrl -Headers $headers
        $payload = ConvertTo-JobObject -Jobs $jobs -RepositoryMap $repoMap -BaseUrl $config.VeeamBaseUrl -Headers $headers

        $body = [pscustomobject]@{
            schemaVersion       = $config.SchemaVersion
            sentAt              = (Get-Date).ToUniversalTime().ToString('o')
            client_name         = $config.ClientName
            client_display_name = $config.ClientDisplayName
            runId               = [guid]::NewGuid().ToString()
            maxHoursBackup      = $config.MaxHoursBackup
            data                = ($payload | ConvertFrom-Json)
            vmBackupSummary     = [pscustomobject]@{
                total           = $backupStatus.Count
                withBackup      = $vmsWithBackup.Count
                overdue         = $overdueVMs.Count
                withoutBackup   = $vmsWithoutBackup.Count
            }
            vmBackupStatus      = @($backupStatus)
            protectedVMs        = @($vmsWithBackup | Select-Object -ExpandProperty VM)
            unprotectedVMs      = @($vmsWithoutBackup | Select-Object -ExpandProperty VM)
        }

        if ($NoSave) {
            Write-Log "NoSave param specified, exiting." -Level LOG -Context "N8N"
            exit 0
        }

        $sent = Send-N8nWebhook `
            -WebhookUri $config.N8NUri `
            -Payload $body `
            -headers (Get-Secret -Name 'N8nApiKey' -AsPlainText)

        if (-not $sent) {
            $msg = "O relatorio nao pode ser enviado ao n8n."
            Write-Log $msg -Level ERROR -Context 'N8N'
            throw $msg
        }
        return $body


    } catch {
        Write-Log "Execução abortada: $($_.Exception.Message)" -Level ERROR -Context "MAIN"
        exit 1

    }
}

Main