using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class TpmForegroundConsole
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, width, height, charsX, charsY, fill, flags;
        public short showWindow, reservedSize;
        public IntPtr reservedBytes, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo
    {
        public IntPtr process, thread;
        public int processId, threadId;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string app, StringBuilder command,
        IntPtr processSecurity, IntPtr threadSecurity, bool inherit, int flags,
        IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(int pid);
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(int signal, int group);
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);

    public static void EnableCtrlC()
    {
        // Test runners may pass down the inheritable CTRL+C-ignore attribute.
        if (!SetConsoleCtrlHandler(IntPtr.Zero, false))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static int Start(string command, string directory)
    {
        var startup = new StartupInfo();
        startup.cb = Marshal.SizeOf(startup);
        startup.flags = 1; // STARTF_USESHOWWINDOW
        startup.showWindow = 0; // SW_HIDE
        ProcessInfo info;
        if (!CreateProcess(null, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero,
            false, 0x10, IntPtr.Zero, directory, ref startup, out info))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        CloseHandle(info.thread);
        CloseHandle(info.process);
        return info.processId;
    }

    public static void Signal(int pid, bool close)
    {
        FreeConsole();
        if (!AttachConsole(pid)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            SetConsoleCtrlHandler(IntPtr.Zero, true);
            if (close)
            {
                var window = GetConsoleWindow();
                if (window == IntPtr.Zero || !PostMessage(window, 0x10, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            else if (!GenerateConsoleCtrlEvent(0, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            Thread.Sleep(300);
        }
        finally { FreeConsole(); }
    }
}
