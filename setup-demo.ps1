# ============================================
# Menu Interativo - Demo Sistemas Distribuidos
# ============================================

$faultToleranceUrl = "http://localhost:30000"

Write-Host "`nVerificando se a aplicacao esta rodando..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Uri "$faultToleranceUrl/health" -TimeoutSec 5 | Out-Null
    Write-Host "Aplicacao detectada!" -ForegroundColor Green
} catch {
    Write-Host "Aplicacao nao encontrada. Execute .\setup.ps1 primeiro." -ForegroundColor Red
    exit 1
}

do {
    Write-Host "`n============================================" -ForegroundColor Magenta
    Write-Host "  Menu de Demo - Sistemas Distribuidos" -ForegroundColor Magenta
    Write-Host "============================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  -- Experimentos Chaos --" -ForegroundColor Cyan
    Write-Host "  1 - Apenas NetworkChaos (latencia + perda)"
    Write-Host "  2 - Apenas PodChaos (kill de pod)"
    Write-Host "  3 - Apenas StressChaos (CPU)"
    Write-Host "  4 - Todos os experimentos"
    Write-Host "  5 - Remover todos experimentos"
    Write-Host ""
    Write-Host "  -- Sistema Anti-Falhas --" -ForegroundColor Yellow
    Write-Host "  6 - DESLIGAR todos (mostrar erros)"
    Write-Host "  7 - LIGAR todos (sistema resiliente)"
    Write-Host "  8 - Ver status dos toggles"
    Write-Host "  9 - Toggle manual (escolher componente)"
    Write-Host " 10 - Modo DEFEITO (timeout ON, CB+Retry OFF)"
    Write-Host " 11 - Limpar cache Redis (flush)"
    Write-Host "  12 - Simular latencia (servico lento)"
    Write-Host "  13 - Restaurar servico normal"
    Write-Host ""
    Write-Host "  -- Observabilidade --" -ForegroundColor Cyan
    Write-Host "  14 - Ver metricas Prometheus (raw)"
    Write-Host "  15 - Port-forward Grafana (localhost:30030)"
    Write-Host "  16 - Port-forward Prometheus (localhost:9090)"
    Write-Host ""
    Write-Host "  0 - Sair" -ForegroundColor Gray
    Write-Host "============================================" -ForegroundColor Magenta

    $choice = Read-Host "`nEscolha uma opcao"

    switch ($choice) {
        "1" {
            kubectl delete -f chaos/pod-chaos.yaml -f chaos/stress-chaos.yaml 2>$null
            kubectl apply -f chaos/network-chaos.yaml
            Write-Host "NetworkChaos aplicado!" -ForegroundColor Green
        }
        "2" {
            kubectl delete -f chaos/network-chaos.yaml -f chaos/stress-chaos.yaml 2>$null
            kubectl apply -f chaos/pod-chaos.yaml
            Write-Host "PodChaos aplicado!" -ForegroundColor Green
        }
        "3" {
            kubectl delete -f chaos/network-chaos.yaml -f chaos/pod-chaos.yaml 2>$null
            kubectl apply -f chaos/stress-chaos.yaml
            Write-Host "StressChaos aplicado!" -ForegroundColor Green
        }
        "4" {
            kubectl apply -f chaos/
            Write-Host "Todos experimentos aplicados!" -ForegroundColor Green
        }
        "5" {
            kubectl delete -f chaos/ --wait=false 2>$null
            Write-Host "Experimentos removidos!" -ForegroundColor Green
            Start-Sleep -Seconds 2
        }
        "6" {
            try {
                Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/toggle?cb=false&retry=false&timeout=false" | ConvertTo-Json | Write-Host
                Write-Host "Anti-falhas DESLIGADOS!" -ForegroundColor Red
            } catch {
                Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
            }
        }
        "7" {
            try {
                Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/toggle?cb=true&retry=true&timeout=true" | ConvertTo-Json | Write-Host
                Write-Host "Anti-falhas LIGADOS!" -ForegroundColor Green
            } catch {
                Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
            }
        }
        "8" {
            try {
                $status = Invoke-RestMethod -Uri "$faultToleranceUrl/admin/status"
                Write-Host ""
                Write-Host "  Circuit Breaker: $(if ($status.circuit_breaker) { 'LIGADO' } else { 'DESLIGADO' })" -ForegroundColor $(if ($status.circuit_breaker) { 'Green' } else { 'Red' })
                Write-Host "  Retry:          $(if ($status.retry) { 'LIGADO' } else { 'DESLIGADO' })" -ForegroundColor $(if ($status.retry) { 'Green' } else { 'Red' })
                Write-Host "  Timeout:        $(if ($status.timeout) { 'LIGADO' } else { 'DESLIGADO' })" -ForegroundColor $(if ($status.timeout) { 'Green' } else { 'Red' })
                Write-Host "  CB State:       $($status.cb_state)"
            } catch {
                Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
            }
        }
        "9" {
            Write-Host ""
            Write-Host "  a) Circuit Breaker: $(try { (Invoke-RestMethod -Uri "$faultToleranceUrl/admin/status").circuit_breaker } catch { '?' })" -ForegroundColor Yellow
            Write-Host "  b) Retry:          $(try { (Invoke-RestMethod -Uri "$faultToleranceUrl/admin/status").retry } catch { '?' })" -ForegroundColor Yellow
            Write-Host "  c) Timeout:        $(try { (Invoke-RestMethod -Uri "$faultToleranceUrl/admin/status").timeout } catch { '?' })" -ForegroundColor Yellow
            Write-Host ""
            $component = Read-Host "Componente (a/b/c)"
            $state = Read-Host "Estado (true/false)"
            $param = switch ($component) { "a" { "cb" } "b" { "retry" } "c" { "timeout" } default { "" } }
            if ($param -and $state -in @("true", "false")) {
                try {
                    Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/toggle?$param=$state" | ConvertTo-Json | Write-Host
                    Write-Host "Toggle atualizado!" -ForegroundColor Green
                } catch {
                    Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
                }
            } else {
                Write-Host "Opcao invalida!" -ForegroundColor Yellow
            }
        }
        "10" {
            try {
                Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/toggle?cb=false&retry=false&timeout=true" | ConvertTo-Json | Write-Host
                Write-Host "Modo DEFEITO: Timeout LIGADO, CB+Retry DESLIGADOS" -ForegroundColor Yellow
                Write-Host "Requisicoes que excederam 2s vao retornar ERRO direto!" -ForegroundColor Yellow
            } catch {
                Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
            }
        }
        "11" {
            try {
                $result = Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/flush"
                if ($result.flushed) {
                    Write-Host "Cache Redis limpo!" -ForegroundColor Green
                } else {
                    Write-Host "Erro ao limpar cache: $($result.error)" -ForegroundColor Red
                }
            } catch {
                Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
            }
        }
        "12" {
            try {
                Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/slow?ms=3000" | Out-Null
                Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/flush" | Out-Null
                Write-Host "Servico em MODO LENTO (3000ms de delay)" -ForegroundColor Red
                Write-Host "Combine com Modo DEFEITO (opcao 10) para ver timeouts!" -ForegroundColor Yellow
            } catch {
                Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
            }
        }
        "13" {
            try {
                Invoke-RestMethod -Method POST -Uri "$faultToleranceUrl/admin/slow?ms=50" | Out-Null
                Write-Host "Servico restaurado para modo normal (50ms)" -ForegroundColor Green
            } catch {
                Write-Host "Erro ao comunicar com gateway: $_" -ForegroundColor Red
            }
        }
        "14" {
            try {
                $response = Invoke-RestMethod -Uri "http://localhost:30090/api/v1/query?query=gateway_requests_total" -TimeoutSec 5
                Write-Host "`nMetricas Gateway (amostra):" -ForegroundColor Cyan
                $response.data.result | Select-Object -First 5 | ForEach-Object {
                    Write-Host "  $($_.metric.method) $($_.metric.endpoint) [$($_.metric.status)]: $($_.value[1])" -ForegroundColor White
                }
                $response2 = Invoke-RestMethod -Uri "http://localhost:30090/api/v1/query?query=servico_requests_total" -TimeoutSec 5
                Write-Host "`nMetricas Servico (amostra):" -ForegroundColor Cyan
                $response2.data.result | Select-Object -First 5 | ForEach-Object {
                    Write-Host "  $($_.metric.method) $($_.metric.endpoint) [$($_.metric.status)]: $($_.value[1])" -ForegroundColor White
                }
                $response3 = Invoke-RestMethod -Uri "http://localhost:30090/api/v1/query?query=gateway_circuit_breaker_state" -TimeoutSec 5
                Write-Host "`nCircuit Breaker State:" -ForegroundColor Cyan
                $stateMap = @{ "0"="CLOSED"; "1"="OPEN"; "2"="HALF_OPEN" }
                $response3.data.result | ForEach-Object {
                    $stateVal = [string][math]::Round([double]$_.value[1])
                    Write-Host "  State: $($stateMap[$stateVal])" -ForegroundColor $(if ($stateVal -eq "0") { "Green" } elseif ($stateVal -eq "1") { "Red" } else { "Yellow" })
                }
            } catch {
                Write-Host "Prometheus indisponivel. Verifique: kubectl get pods -l app=prometheus" -ForegroundColor Yellow
            }
        }
        "15" {
            Write-Host "Iniciando port-forward Grafana -> http://localhost:30030" -ForegroundColor Cyan
            Write-Host "Login: admin / admin" -ForegroundColor Yellow
            Start-Process powershell -ArgumentList "-Command", "kubectl port-forward -n trabalho-sis-dis svc/grafana 30030:3000" -WindowStyle Normal
        }
        "16" {
            Write-Host "Iniciando port-forward Prometheus -> http://localhost:9090" -ForegroundColor Cyan
            Start-Process powershell -ArgumentList "-Command", "kubectl port-forward -n trabalho-sis-dis svc/prometheus 30090:9090" -WindowStyle Normal
        }
        "0" {
            Write-Host "Saindo..." -ForegroundColor Gray
        }
        default {
            Write-Host "Opcao invalida!" -ForegroundColor Yellow
        }
    }
} while ($choice -ne "0")
