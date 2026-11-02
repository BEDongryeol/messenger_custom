// Dooray Skin Windows 설치 프로그램 (자가 추출 스텁)
//  - build-windows.ps1 이 Windows 내장 csc.exe 로 컴파일하며 payload 파일들을 리소스(파일명 = 리소스명)로 넣는다.
//  - 실행하면 %APPDATA%\DooraySkin 에 리소스를 풀고 setup.ps1 을 숨김 PowerShell 로 실행, 진행 내용을 창에 보여 준다.
//  - "/uninstall" 인수로 실행하면 uninstall.ps1 을 실행한다.
//  - 관리자 권한 불필요(현재 사용자 폴더·레지스트리만 사용).
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool uninstall = args.Length > 0 && args[0].Equals("/uninstall", StringComparison.OrdinalIgnoreCase);
        var form = new SetupForm(uninstall);
        Application.Run(form);
        return form.ExitCode;
    }
}

class SetupForm : Form
{
    readonly bool uninstall;
    readonly Label label = new Label();
    readonly ProgressBar bar = new ProgressBar();
    readonly TextBox log = new TextBox();
    readonly Button ok = new Button();
    readonly System.Windows.Forms.Timer closeTimer = new System.Windows.Forms.Timer();
    int countdown = 8;
    public int ExitCode = 1;

    public SetupForm(bool uninstall)
    {
        this.uninstall = uninstall;
        Text = "Dooray Skin " + (uninstall ? "제거" : "설치");
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(540, 320);
        Font = new Font("Malgun Gothic", 9.5f);

        label.Text = uninstall
            ? "Dooray Skin 을 제거하는 중입니다..."
            : "Dooray Skin 을 설치하는 중입니다. Dooray 를 찾고 바로가기를 바꾸는 데 몇 초 걸립니다.";
        label.SetBounds(16, 14, 508, 40);
        bar.SetBounds(16, 58, 508, 18);
        bar.Style = ProgressBarStyle.Marquee;
        log.SetBounds(16, 86, 508, 184);
        log.Multiline = true;
        log.ReadOnly = true;
        log.ScrollBars = ScrollBars.Vertical;
        log.Font = new Font("Consolas", 9f);
        log.BackColor = Color.White;
        ok.Text = "확인";
        ok.SetBounds(424, 280, 100, 28);
        ok.Enabled = false;
        ok.Click += (s, e) => Close();
        Controls.AddRange(new Control[] { label, bar, log, ok });
        closeTimer.Interval = 1000;
        closeTimer.Tick += (s, e) =>
        {
            countdown--;
            ok.Text = "확인 (" + countdown + ")";
            if (countdown <= 0) Close();
        };
        Shown += (s, e) => new Thread(Run) { IsBackground = true }.Start();
    }

    void Run()
    {
        int rc = 1;
        try
        {
            string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DooraySkin");
            Directory.CreateDirectory(data);
            var asm = Assembly.GetExecutingAssembly();
            foreach (string name in asm.GetManifestResourceNames())
            {
                using (var s = asm.GetManifestResourceStream(name))
                using (var f = File.Create(Path.Combine(data, name))) s.CopyTo(f);
            }
            Append("파일 복사: " + data);
            string script = Path.Combine(data, uninstall ? "uninstall.ps1" : "setup.ps1");
            var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = data,
            };
            psi.EnvironmentVariables["DRB_SETUP_EXE"] = Application.ExecutablePath;
            using (var p = Process.Start(psi))
            {
                p.OutputDataReceived += (s, e) => { if (e.Data != null) Append(e.Data); };
                p.ErrorDataReceived += (s, e) => { if (e.Data != null) Append(e.Data); };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                p.WaitForExit();
                rc = p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Append("오류: " + ex.Message);
        }
        ExitCode = rc;
        try
        {
            BeginInvoke(new Action(() =>
            {
                bar.Style = ProgressBarStyle.Continuous;
                bar.Value = 100;
                ok.Enabled = true;
                ok.Focus();
                if (rc == 0)
                {
                    label.Text = uninstall ? "제거가 끝났습니다." : "설치가 끝났습니다. Dooray 가 Dooray Skin 적용 상태로 다시 실행됩니다.";
                    ok.Text = "확인 (" + countdown + ")";
                    closeTimer.Start();
                }
                else
                {
                    label.Text = "실패했습니다 (코드 " + rc + "). 아래 내용을 캡처해서 전달해 주세요.";
                }
            }));
        }
        catch { }
    }

    void Append(string line)
    {
        try { BeginInvoke(new Action(() => log.AppendText(line + Environment.NewLine))); } catch { }
    }
}
