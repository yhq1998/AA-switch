using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace AASwitch.Core;

/// <summary>存 API key 的地方。条目名与 macOS 版一致：codex-mode:域名，Codex 和 Claude Code 共用。</summary>
public interface ISecretStore
{
    string? Get(string name);
    void Set(string name, string secret);
    bool Delete(string name);
}

public sealed class MemorySecretStore : ISecretStore
{
    readonly Dictionary<string, string> _items = [];
    public string? Get(string name) => _items.GetValueOrDefault(name);
    public void Set(string name, string secret) => _items[name] = secret;
    public bool Delete(string name) => _items.Remove(name);
}

/// <summary>Windows 凭据管理器（“Windows 凭据 → 普通凭据”），按当前用户用 DPAPI 加密。</summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsCredentialStore : ISecretStore
{
    const uint CredTypeGeneric = 1, PersistLocalMachine = 2;
    const int ErrorNotFound = 1168;

    public string? Get(string name)
    {
        if (!CredRead(name, CredTypeGeneric, 0, out var ptr))
        {
            var err = Marshal.GetLastWin32Error();
            if (err == ErrorNotFound) return null;
            throw new Win32Exception(err);
        }
        try
        {
            var cred = Marshal.PtrToStructure<Credential>(ptr);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return "";
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.Unicode.GetString(bytes);
        }
        finally { CredFree(ptr); }
    }

    public void Set(string name, string secret)
    {
        var blob = Encoding.Unicode.GetBytes(secret);
        if (blob.Length > 2560) throw new SwitchException("key 太长，Windows 凭据管理器存不下。");
        var target = Marshal.StringToCoTaskMemUni(name);
        var user = Marshal.StringToCoTaskMemUni(Environment.UserName);
        var blobPtr = Marshal.AllocCoTaskMem(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, blobPtr, blob.Length);
            var cred = new Credential
            {
                Type = CredTypeGeneric, TargetName = target, UserName = user,
                CredentialBlob = blobPtr, CredentialBlobSize = (uint)blob.Length, Persist = PersistLocalMachine,
            };
            if (!CredWrite(ref cred, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            Marshal.FreeCoTaskMem(target); Marshal.FreeCoTaskMem(user); Marshal.FreeCoTaskMem(blobPtr);
        }
    }

    public bool Delete(string name)
    {
        if (CredDelete(name, CredTypeGeneric, 0)) return true;
        var err = Marshal.GetLastWin32Error();
        if (err == ErrorNotFound) return false;
        throw new Win32Exception(err);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Credential
    {
        public uint Flags, Type;
        public IntPtr TargetName, Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes, TargetAlias, UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWrite(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);
}

/// <summary>相当于脚本里的 die：带一句给用户看的中文说明。</summary>
public sealed class SwitchException(string message) : Exception(message);
