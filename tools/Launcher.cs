using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

internal static class Launcher
{
    [STAThread]
    private static int Main()
    {
        string appDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string scriptPath = Path.Combine(appDir, "src", "App.ps1");

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show("Missing src\\App.ps1. ASC Radar cannot start.", "ASC Radar", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }

        try
        {
            Directory.SetCurrentDirectory(appDir);
            string scriptText = File.ReadAllText(scriptPath);
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.ReuseThread;
                runspace.Open();
                runspace.SessionStateProxy.SetVariable("ASCRadarAppRoot", appDir);

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddScript(scriptText, false);
                    ps.Invoke();

                    if (ps.Streams.Error.Count > 0)
                    {
                        MessageBox.Show(ps.Streams.Error[0].ToString(), "ASC Radar", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return 1;
                    }
                }
            }

            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "ASC Radar", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }
}
