param(
    [Parameter(Mandatory = $true)]
    [string]$WebAppId
)

$ErrorActionPreference = 'Stop'

$projectId = 'pizarraliga'
$configPath = Join-Path $env:TEMP "pizarraliga-web-config-$([guid]::NewGuid().ToString('N')).json"

try {
    & firebase.cmd apps:sdkconfig WEB $webAppId --out $configPath --project $projectId
    if ($LASTEXITCODE -ne 0) {
        throw 'No se pudo obtener la configuración de Firebase para la app web.'
    }

    $config = Get-Content -Raw $configPath | ConvertFrom-Json
    foreach ($name in @('apiKey', 'appId', 'messagingSenderId', 'projectId')) {
        if ([string]::IsNullOrWhiteSpace($config.$name)) {
            throw "La configuración de Firebase no contiene $name."
        }
    }

    $buildArgs = @(
        'build', 'web', '--release',
        "--dart-define=FIREBASE_WEB_API_KEY=$($config.apiKey)",
        "--dart-define=FIREBASE_WEB_APP_ID=$($config.appId)",
        "--dart-define=FIREBASE_MESSAGING_SENDER_ID=$($config.messagingSenderId)",
        "--dart-define=FIREBASE_PROJECT_ID=$($config.projectId)"
    )
    if (-not [string]::IsNullOrWhiteSpace($config.authDomain)) {
        $buildArgs += "--dart-define=FIREBASE_AUTH_DOMAIN=$($config.authDomain)"
    }
    if (-not [string]::IsNullOrWhiteSpace($config.storageBucket)) {
        $buildArgs += "--dart-define=FIREBASE_STORAGE_BUCKET=$($config.storageBucket)"
    }

    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'Falló la compilación web de Flutter.'
    }

    & firebase.cmd deploy --only hosting,firestore:rules --project $projectId
    if ($LASTEXITCODE -ne 0) {
        throw 'Falló el despliegue de Firebase Hosting o de las reglas de Firestore.'
    }
} finally {
    if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath
    }
}
