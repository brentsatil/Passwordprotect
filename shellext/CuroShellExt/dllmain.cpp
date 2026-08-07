// Curo PDF Protector - Windows 11 modern context-menu handler.
//
// Windows 11 only shows an extension in the DEFAULT (compact) context menu if
// BOTH of Microsoft's conditions are met: the command implements
// IExplorerCommand, and the app has package identity at runtime. A plain
// registry verb - which is what install.ps1 writes - satisfies neither, so it
// is demoted to "Show more options". This DLL is the IExplorerCommand half;
// the sparse MSIX beside it supplies the package identity.
//
// Native C++ on purpose: Explorer loads context-menu handlers IN-PROCESS, and
// putting a managed runtime inside Explorer is a well-known way to destabilise
// the shell. There is nothing here that needs more than Win32.
//
// The command itself does no work - it launches PasswordProtect.exe with the
// selected paths, so the modern menu, the legacy menu and drag-and-drop all
// run the identical, audited PowerShell tool.

#include <windows.h>
#include <shobjidl_core.h>
#include <shlwapi.h>
#include <objbase.h>
#include <string>
#include <vector>
#include <new>

#pragma comment(lib, "shlwapi.lib")

// Must match the Clsid in the sparse package's AppxManifest.xml exactly.
// {E9143454-7592-4892-BAFA-1DD9507FB947}
static const CLSID CLSID_CuroProtectCommand =
    { 0xE9143454, 0x7592, 0x4892, { 0xBA, 0xFA, 0x1D, 0xD9, 0x50, 0x7F, 0xB9, 0x47 } };

static HMODULE g_hModule = nullptr;
static LONG    g_refs    = 0;

static void DllAddRef()  { InterlockedIncrement(&g_refs); }
static void DllRelease() { InterlockedDecrement(&g_refs); }

// PasswordProtect.exe is deployed beside this DLL (both live in the sparse
// package's external location), so resolve it relative to our own module
// rather than trusting PATH or a hard-coded install directory.
static std::wstring GetLauncherPath()
{
    wchar_t buf[MAX_PATH] = {};
    if (!GetModuleFileNameW(g_hModule, buf, MAX_PATH)) return L"";
    PathRemoveFileSpecW(buf);
    std::wstring p(buf);
    p += L"\\PasswordProtect.exe";
    return p;
}

// Windows command-line quoting (CommandLineToArgvW rules).
static std::wstring QuoteArg(const std::wstring& arg)
{
    if (!arg.empty() && arg.find_first_of(L" \t\"") == std::wstring::npos) return arg;
    std::wstring out = L"\"";
    size_t slashes = 0;
    for (wchar_t c : arg)
    {
        if (c == L'\\') { ++slashes; continue; }
        if (c == L'"')  { out.append(slashes * 2 + 1, L'\\'); out.push_back(L'"'); slashes = 0; continue; }
        out.append(slashes, L'\\'); slashes = 0;
        out.push_back(c);
    }
    out.append(slashes * 2, L'\\');
    out.push_back(L'"');
    return out;
}

class CuroProtectCommand : public IExplorerCommand
{
public:
    CuroProtectCommand() : m_refs(1) { DllAddRef(); }

    // IUnknown
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand)
        {
            *ppv = static_cast<IExplorerCommand*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() override
    {
        LONG n = InterlockedDecrement(&m_refs);
        if (n == 0) delete this;
        return n;
    }

    // IExplorerCommand
    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* ppszName) override
    {
        return SHStrDupW(L"Protect with password", ppszName);
    }

    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* ppszIcon) override
    {
        std::wstring exe = GetLauncherPath();
        if (exe.empty()) { *ppszIcon = nullptr; return E_FAIL; }
        exe += L",0";
        return SHStrDupW(exe.c_str(), ppszIcon);
    }

    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* ppszInfotip) override
    {
        *ppszInfotip = nullptr;
        return E_NOTIMPL;   // Explorer falls back to the title.
    }

    IFACEMETHODIMP GetCanonicalName(GUID* pguidCommandName) override
    {
        *pguidCommandName = CLSID_CuroProtectCommand;
        return S_OK;
    }

    // Enabled only when every selected item is a PDF. The tool is PDF-only by
    // design (docs\RISK.md #5); greying the verb out is friendlier than
    // launching and refusing.
    IFACEMETHODIMP GetState(IShellItemArray* psiItemArray, BOOL, EXPCMDSTATE* pCmdState) override
    {
        *pCmdState = ECS_ENABLED;
        if (!psiItemArray) { *pCmdState = ECS_HIDDEN; return S_OK; }

        DWORD count = 0;
        if (FAILED(psiItemArray->GetCount(&count)) || count == 0) { *pCmdState = ECS_HIDDEN; return S_OK; }

        for (DWORD i = 0; i < count; ++i)
        {
            IShellItem* item = nullptr;
            if (FAILED(psiItemArray->GetItemAt(i, &item)) || !item) { *pCmdState = ECS_DISABLED; return S_OK; }
            LPWSTR path = nullptr;
            HRESULT hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
            bool isPdf = false;
            if (SUCCEEDED(hr) && path)
            {
                LPCWSTR ext = PathFindExtensionW(path);
                isPdf = (ext && _wcsicmp(ext, L".pdf") == 0);
                CoTaskMemFree(path);
            }
            item->Release();
            if (!isPdf) { *pCmdState = ECS_DISABLED; return S_OK; }
        }
        return S_OK;
    }

    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* pFlags) override
    {
        *pFlags = ECF_DEFAULT;
        return S_OK;
    }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** ppEnum) override
    {
        *ppEnum = nullptr;
        return E_NOTIMPL;
    }

    IFACEMETHODIMP Invoke(IShellItemArray* psiItemArray, IBindCtx*) override
    {
        if (!psiItemArray) return E_INVALIDARG;

        std::wstring exe = GetLauncherPath();
        if (exe.empty()) return E_FAIL;

        DWORD count = 0;
        HRESULT hr = psiItemArray->GetCount(&count);
        if (FAILED(hr) || count == 0) return E_INVALIDARG;

        std::wstring cmd = QuoteArg(exe);
        for (DWORD i = 0; i < count; ++i)
        {
            IShellItem* item = nullptr;
            if (FAILED(psiItemArray->GetItemAt(i, &item)) || !item) continue;
            LPWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path)
            {
                cmd += L" ";
                cmd += QuoteArg(path);
                CoTaskMemFree(path);
            }
            item->Release();
        }

        STARTUPINFOW si = {};
        si.cb = sizeof(si);
        PROCESS_INFORMATION pi = {};

        // CreateProcessW may write to the command line buffer.
        std::vector<wchar_t> mutableCmd(cmd.begin(), cmd.end());
        mutableCmd.push_back(L'\0');

        // Working directory deliberately unset: Explorer's cwd can be a path
        // that disappears, and the tool only ever uses absolute paths.
        if (!CreateProcessW(nullptr, mutableCmd.data(), nullptr, nullptr, FALSE,
                            CREATE_UNICODE_ENVIRONMENT, nullptr, nullptr, &si, &pi))
        {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return S_OK;
    }

private:
    ~CuroProtectCommand() { DllRelease(); }
    LONG m_refs;
};

class ClassFactory : public IClassFactory
{
public:
    ClassFactory() : m_refs(1) { DllAddRef(); }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IClassFactory)
        {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() override
    {
        LONG n = InterlockedDecrement(&m_refs);
        if (n == 0) delete this;
        return n;
    }

    IFACEMETHODIMP CreateInstance(IUnknown* pUnkOuter, REFIID riid, void** ppv) override
    {
        if (pUnkOuter) return CLASS_E_NOAGGREGATION;
        CuroProtectCommand* cmd = new (std::nothrow) CuroProtectCommand();
        if (!cmd) return E_OUTOFMEMORY;
        HRESULT hr = cmd->QueryInterface(riid, ppv);
        cmd->Release();
        return hr;
    }

    IFACEMETHODIMP LockServer(BOOL fLock) override
    {
        if (fLock) DllAddRef(); else DllRelease();
        return S_OK;
    }

private:
    ~ClassFactory() { DllRelease(); }
    LONG m_refs;
};

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv)
{
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (rclsid != CLSID_CuroProtectCommand) return CLASS_E_CLASSNOTAVAILABLE;

    ClassFactory* factory = new (std::nothrow) ClassFactory();
    if (!factory) return E_OUTOFMEMORY;
    HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

STDAPI DllCanUnloadNow()
{
    return (g_refs == 0) ? S_OK : S_FALSE;
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_hModule = hModule;
        DisableThreadLibraryCalls(hModule);
    }
    return TRUE;
}
