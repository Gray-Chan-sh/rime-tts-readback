#Requires -Version 5.1
<#
    build-exe.ps1 - package rime-tts-readback into a single self-extracting .exe.

    The exe embeds the whole project as resources. On run it extracts to
        %LOCALAPPDATA%\RimeTtsReadback\<version>\
    (only when version/content changes) and launches the control panel.

    Uses the C# compiler that ships with Windows (csc.exe) - no downloads needed.

    Usage:
        powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1
        powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1 -Version 1.0.1
#>
param(
    [string]$Version,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $Version) {
    $gui = Join-Path $root 'windows\RimeTtsReadback.Gui.ps1'
    if (Test-Path -LiteralPath $gui) {
        $m = [regex]::Match((Get-Content -LiteralPath $gui -Raw -Encoding UTF8), "AppVersion\s*=\s*'([0-9][0-9.]*)'")
        if ($m.Success) { $Version = $m.Groups[1].Value }
    }
    if (-not $Version) { $Version = '0.0.0' }
}
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$exe = Join-Path $OutDir ("RimeTtsReadback-" + $Version + ".exe")
$stage = Join-Path $env:TEMP ("rttr-exe-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# ---- collect the payload: relative path (forward slashes) -> real file path
# Relative paths are built from directory NAMES only (never by slicing FullName),
# so short/long path forms on CI runners cannot corrupt them.
$entries = New-Object System.Collections.Generic.List[object]
function Add-Tree([string]$dirPath, [string]$relPrefix) {
    foreach ($f in (Get-ChildItem -LiteralPath $dirPath -File | Sort-Object Name)) {
        $entries.Add([PSCustomObject]@{ Rel = ($relPrefix + $f.Name); Path = $f.FullName })
    }
    foreach ($d in (Get-ChildItem -LiteralPath $dirPath -Directory | Sort-Object Name)) {
        Add-Tree $d.FullName ($relPrefix + $d.Name + '/')
    }
}
$items = @('README.md', 'LICENSE', 'install.ps1', 'uninstall.ps1', 'rime', 'windows', 'icons', 'tools')
foreach ($i in $items) {
    $src = Join-Path $root $i
    if (-not (Test-Path -LiteralPath $src)) { Write-Warning "missing: $i"; continue }
    if ((Get-Item -LiteralPath $src).PSIsContainer) { Add-Tree $src ($i + '/') }
    else { $entries.Add([PSCustomObject]@{ Rel = $i; Path = (Get-Item -LiteralPath $src).FullName }) }
}
$verFile = Join-Path $stage 'VERSION.txt'
[System.IO.File]::WriteAllText($verFile, $Version, (New-Object System.Text.ASCIIEncoding))
$entries.Add([PSCustomObject]@{ Rel = 'VERSION.txt'; Path = $verFile })

$entries = @($entries | Sort-Object Rel)
$rel = @($entries | ForEach-Object { $_.Rel })
$manifestPath = Join-Path $stage 'manifest.txt'
[System.IO.File]::WriteAllText($manifestPath, ($rel -join "`n"), (New-Object System.Text.ASCIIEncoding))

# ---- launcher source (ASCII only)
$launcher = @'
using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Text;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            var asm = Assembly.GetExecutingAssembly();

            string manifest;
            using (var s = asm.GetManifestResourceStream("manifest"))
            using (var r = new StreamReader(s, Encoding.UTF8))
                manifest = r.ReadToEnd();
            var paths = manifest.Replace("\r", "").Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);

            string version = "0";
            for (int i = 0; i < paths.Length; i++)
            {
                if (string.Equals(paths[i], "VERSION.txt", StringComparison.OrdinalIgnoreCase))
                {
                    using (var s = asm.GetManifestResourceStream("f" + i))
                    using (var r = new StreamReader(s, Encoding.UTF8))
                        version = r.ReadToEnd().Trim();
                    break;
                }
            }

            string dir = Path.Combine(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RimeTtsReadback"),
                version);
            string stamp = Path.Combine(dir, ".extracted");

            // stamp = version + content hash, so a rebuilt exe re-extracts even at the same version
            uint h = 2166136261;
            foreach (byte b in Encoding.UTF8.GetBytes(manifest)) { h ^= b; h *= 16777619; }
            string stampValue = version + "|" + h.ToString("x8");

            bool needExtract = !File.Exists(stamp);
            if (!needExtract)
            {
                try { needExtract = File.ReadAllText(stamp).Trim() != stampValue; } catch { needExtract = true; }
            }

            if (needExtract)
            {
                Directory.CreateDirectory(dir);
                for (int i = 0; i < paths.Length; i++)
                {
                    string target = Path.Combine(dir, paths[i].Replace('/', Path.DirectorySeparatorChar));
                    string parent = Path.GetDirectoryName(target);
                    if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
                    using (var s = asm.GetManifestResourceStream("f" + i))
                    using (var fs = File.Create(target))
                        s.CopyTo(fs);
                }
                File.WriteAllText(stamp, stampValue);
            }

            string gui = Path.Combine(dir, Path.Combine("windows", "RimeTtsReadback.Gui.ps1"));
            var sb = new StringBuilder();
            sb.Append("-NoProfile -STA -ExecutionPolicy Bypass -File \"").Append(gui).Append('"');
            foreach (var a in args) sb.Append(' ').Append('"').Append(a.Replace("\"", "\\\"")).Append('"');

            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = sb.ToString();
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;            // no console window
            psi.WorkingDirectory = dir;
            psi.RedirectStandardOutput = true;    // give the child valid std handles
            psi.RedirectStandardError = true;
            psi.RedirectStandardInput = true;
            var child = Process.Start(psi);
            child.OutputDataReceived += delegate(object s2, DataReceivedEventArgs e2) { };
            child.ErrorDataReceived += delegate(object s2, DataReceivedEventArgs e2) { };
            child.BeginOutputReadLine();
            child.BeginErrorReadLine();
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.ToString(), "Rime TTS Readback", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
'@
$csPath = Join-Path $stage 'Launcher.cs'
[System.IO.File]::WriteAllText($csPath, $launcher, (New-Object System.Text.ASCIIEncoding))

# ---- compile
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) { throw 'csc.exe not found' }

$icon = Join-Path $root 'icons\rime-tts-readback.ico'
$cscArgs = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', ('/out:' + $exe),
             '/reference:System.dll', '/reference:System.Windows.Forms.dll')
if (Test-Path -LiteralPath $icon) { $cscArgs += ('/win32icon:' + $icon) }
$cscArgs += ('/resource:' + $manifestPath + ',manifest')
for ($i = 0; $i -lt $entries.Count; $i++) {
    $cscArgs += ('/resource:' + $entries[$i].Path + ',f' + $i)
}
$cscArgs += $csPath

& $csc $cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

Remove-Item -LiteralPath $stage -Recurse -Force
$fi = Get-Item -LiteralPath $exe
Write-Host ("built: " + $fi.FullName + "  (" + [math]::Round($fi.Length / 1KB, 1) + " KB, " + $entries.Count + " embedded files)")
