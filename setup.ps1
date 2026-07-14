# ============================================
# Script de Setup - Trabalho Sistemas Distribuidos
# ============================================

Write-Host "=== Verificando dependencias ===" -ForegroundColor Cyan

$missing = @()

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $missing += "Docker Desktop"
} else {
    Write-Host "[OK] Docker" -ForegroundColor Green
}

if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
    $missing += "Kind"
} else {
    Write-Host "[OK] Kind" -ForegroundColor Green
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    $missing += "kubectl"
} else {
    Write-Host "[OK] kubectl" -ForegroundColor Green
}

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    $missing += "Helm"
} else {
    Write-Host "[OK] Helm" -ForegroundColor Green
}

if ($missing.Count -gt 0) {
    Write-Host "`nFerramentas faltando: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host "Instale antes de continuar:"
    Write-Host "  - Docker Desktop: https://www.docker.com/products/docker-desktop"
    Write-Host "  - Kind: winget install Kubernetes.kind"
    Write-Host "  - kubectl: winget install Kubernetes.kubectl"
    Write-Host "  - Helm: winget install Helm.Helm"
    exit 1
}

Write-Host "`n=== (1/7) Criando cluster Kind ===" -ForegroundColor Cyan
kind delete cluster --name kind 2>$null
kind create cluster --config kind-config.yaml
if (-not $?) { Write-Host "Falha ao criar cluster" -ForegroundColor Red; exit 1 }

Write-Host "`n=== (2/7) Build das imagens Docker ===" -ForegroundColor Cyan
docker build -t gateway:latest -f docker/gateway.Dockerfile .
if (-not $?) { Write-Host "Falha no build da gateway" -ForegroundColor Red; exit 1 }

docker build -t servico:latest -f docker/servico.Dockerfile .
if (-not $?) { Write-Host "Falha no build do servico" -ForegroundColor Red; exit 1 }

Write-Host "`n=== (3/7) Carregando imagens no Kind ===" -ForegroundColor Cyan
kind load docker-image gateway:latest
kind load docker-image servico:latest

Write-Host "`n=== (4/7) Deploy da aplicacao ===" -ForegroundColor Cyan
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/

Write-Host "`nAguardando pods ficarem prontos (60s max)..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod -l app=gateway -n trabalho-sis-dis --timeout=60s
kubectl wait --for=condition=ready pod -l app=servico -n trabalho-sis-dis --timeout=60s
kubectl wait --for=condition=ready pod -l app=redis -n trabalho-sis-dis --timeout=60s

Write-Host "`n=== (5/7) Instalando Chaos Mesh ===" -ForegroundColor Cyan
helm repo add chaos-mesh https://charts.chaos-mesh.org 2>$null
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace

Write-Host "`nAguardando Chaos Mesh (120s max)..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod -n chaos-mesh --all --timeout=120s

Write-Host "`n=== (6/7) Aplicando experimentos de caos ===" -ForegroundColor Cyan
kubectl apply -f chaos/

Write-Host "`n=== (7/7) Testando a aplicacao ===" -ForegroundColor Cyan
Start-Sleep -Seconds 5

try {
    $response = Invoke-RestMethod -Uri "http://localhost:30000/api/data" -TimeoutSec 10
    Write-Host "`nRESPOSTA:" -ForegroundColor Green
    $response | ConvertTo-Json
    Write-Host "`n[SUCESSO] Aplicacao funcionando!" -ForegroundColor Green
} catch {
    Write-Host "`n[AVISO] Falha no teste inicial. Verifique os pods:" -ForegroundColor Yellow
    kubectl get pods -n trabalho-sis-dis
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Setup concluido!" -ForegroundColor Green
Write-Host "  Teste: curl http://localhost:30000/api/data" -ForegroundColor White
Write-Host "  Logs: kubectl logs -n trabalho-sis-dis -l app=gateway" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan

# Menu interativo (loop)
do {
    Write-Host "`n--- Menu de Experimentos Chaos ---" -ForegroundColor Magenta
    Write-Host "1 - Apenas NetworkChaos (latencia + perda)"
    Write-Host "2 - Apenas PodChaos (kill de pod)"
    Write-Host "3 - Apenas StressChaos (CPU)"
    Write-Host "4 - Todos os experimentos"
    Write-Host "5 - Remover todos experimentos"
    Write-Host "0 - Sair"

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
        "0" {
            Write-Host "Saindo..." -ForegroundColor Gray
        }
        default {
            Write-Host "Opcao invalida!" -ForegroundColor Yellow
        }
    }
} while ($choice -ne "0")
