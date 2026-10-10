#Requires -Version 5.1
<#
    build-exe.ps1 - package rime-tts-readback into a single self-extracting .exe.

    The exe embeds the whole project as resources. On run it extracts to
        %LOCALAPPDATA%\RimeTtsReadback\<version>\
    (only when the version changes) and launches the control panel.

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
$pkg = Join-Path $stage 'payload'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $pkg | Out-Null

# ---- payload (same file set as the zip build)
$items = @('README.md', 'LICENSE', 'install.ps1', 'uninstall.ps1', 'rime', 'windows', 'icons', 'tools')
foreach ($i in $items) {
    $src = Join-Path $root $i
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $pkg -Recurse -Force
    } else { Write-Warning "missing: $i" }
}
Set-Content -LiteralPath (Join-Path $pkg 'VERSION.txt') -Value $Version -Encoding Ascii

$files = @(Get-ChildItem -LiteralPath $pkg -Recurse -File | Sort-Object FullName)
$rel = @($files | ForEach-Object { $_.FullName.Substring($pkg.Length + 1).Replace('\', '/') })
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
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
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
for ($i = 0; $i -lt $files.Count; $i++) {
    $cscArgs += ('/resource:' + $files[$i].FullName + ',f' + $i)
}
$cscArgs += $csPath

& $csc $cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

Remove-Item -LiteralPath $stage -Recurse -Force
$fi = Get-Item -LiteralPath $exe
Write-Host ("built: " + $fi.FullName + "  (" + [math]::Round($fi.Length / 1KB, 1) + " KB, " + $files.Count + " embedded files)")
