// WslShim.cs - fake wsl.exe for the real-Windows end-to-end test
// (test/e2e/windows/run_e2e_windows.py). Built at test time with the csc.exe
// that ships in every Windows (.NET Framework 4.x), so nothing to install.
//
// It runs:  <E2E_PYTHON> <fake_windows.py> wsl <our raw arguments>
// The raw command line is forwarded byte-for-byte (not re-quoted), so the
// fake sees exactly the quoting wsl-setup.bat used. stdin/stdout/stderr are
// inherited, so output bytes (e.g. UTF-16) pass through untouched, and our
// exit code is the fake's exit code.
using System;
using System.Diagnostics;

static class WslShim
{
    static string ArgsAfterProgramName(string cmdline)
    {
        int i = 0;
        if (cmdline.Length > 0 && cmdline[0] == '"')
        {
            i = cmdline.IndexOf('"', 1);
            i = i < 0 ? cmdline.Length : i + 1;
        }
        else
        {
            while (i < cmdline.Length && cmdline[i] != ' ' && cmdline[i] != '\t') i++;
        }
        return cmdline.Substring(i).TrimStart(' ', '\t');
    }

    static int Main()
    {
        string python = Environment.GetEnvironmentVariable("E2E_PYTHON");
        string fake = Environment.GetEnvironmentVariable("E2E_FAKE");
        if (string.IsNullOrEmpty(python) || string.IsNullOrEmpty(fake))
        {
            Console.Error.WriteLine("WslShim: E2E_PYTHON / E2E_FAKE not set");
            return 99;
        }
        var psi = new ProcessStartInfo(python, "\"" + fake + "\" wsl " + ArgsAfterProgramName(Environment.CommandLine));
        psi.UseShellExecute = false;
        using (var p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}
