$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'cleanup-temp.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Test-ReparsePoint', 'Test-CargoTargetDirectory')) {
    $function = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('cleanup-tag-test-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory((Join-Path $root 'debug\.fingerprint'))
try {
    [IO.File]::WriteAllText((Join-Path $root '.rustc_info.json'), '{}')
    if (Test-CargoTargetDirectory $root) { throw 'Legacy layout without tag was accepted' }
    $signature = 'Signature: 8a477f597d28d172789f06886806bc55'
    foreach ($invalid in @('', 'invalid', "prefix`n$signature", $signature.Substring(0, 42), ([char]0xFEFF + $signature))) {
        [IO.File]::WriteAllText((Join-Path $root 'CACHEDIR.TAG'), $invalid)
        if (Test-CargoTargetDirectory $root) { throw 'Invalid tag was accepted' }
    }
    foreach ($valid in @($signature, "$signature`r`n# Cargo cache")) {
        [IO.File]::WriteAllText((Join-Path $root 'CACHEDIR.TAG'), $valid)
        if (-not (Test-CargoTargetDirectory $root)) { throw 'Valid tag was rejected' }
    }
    Write-Output 'PASS: legacy layout and invalid tags rejected; valid tags accepted.'
} finally {
    # Delete only the exact files and empty directories created by this test.
    foreach ($name in @('CACHEDIR.TAG', '.rustc_info.json')) {
        Remove-Item -LiteralPath (Join-Path $root $name) -Force -ErrorAction SilentlyContinue
    }
    [IO.Directory]::Delete((Join-Path $root 'debug\.fingerprint'))
    [IO.Directory]::Delete((Join-Path $root 'debug'))
    [IO.Directory]::Delete($root)
}
