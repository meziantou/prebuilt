/*
 * psd-tools.exe, the launcher of the psd-tools bundle on Windows (see
 * scripts/build-psd-tools.sh): it runs the Python of the bundle, isolated from
 * the environment (-I: no PYTHONPATH, no user site-packages) and without
 * writing .pyc files (-B), with the command-line tool of the bundle, followed
 * by its own arguments as it received them, and exits with the exit code of
 * Python.
 *
 *   <bundle>\psd-tools.exe
 *   <bundle>\python\python.exe
 *   <bundle>\lib\psd-tools-cli.py
 *
 * A .bat or .cmd launcher would go through cmd.exe, which parses the
 * arguments again (%, ^, &, quotes): this one passes the rest of its own
 * command line to Python untouched, as scripts/verapdf-launcher.c does.
 *
 * Built with llvm-mingw: x86_64-w64-mingw32-clang -municode -O2 -static.
 */

#include <windows.h>
#include <stdio.h>
#include <wchar.h>

/* The arguments of the command line, after the program name, as typed:
 * the program name ends at the first space outside of quotes. */
static const wchar_t* skip_program_name(const wchar_t* command_line)
{
    BOOL quoted = FALSE;
    while (*command_line != L'\0' && (quoted || (*command_line != L' ' && *command_line != L'\t')))
    {
        if (*command_line == L'"')
            quoted = !quoted;
        command_line++;
    }

    while (*command_line == L' ' || *command_line == L'\t')
        command_line++;

    return command_line;
}

/* Ctrl+C reaches every process of the console: Python handles it, and the
 * launcher waits for it to exit. */
static BOOL WINAPI ignore_control_event(DWORD control_type)
{
    (void)control_type;
    return TRUE;
}

int wmain(void)
{
    wchar_t bundle[MAX_PATH];
    DWORD length = GetModuleFileNameW(NULL, bundle, MAX_PATH);
    if (length == 0 || length >= MAX_PATH)
    {
        fwprintf(stderr, L"psd-tools: cannot get the path of the launcher\n");
        return 1;
    }

    wchar_t* separator = wcsrchr(bundle, L'\\');
    if (separator == NULL)
    {
        fwprintf(stderr, L"psd-tools: unexpected launcher path %ls\n", bundle);
        return 1;
    }
    *separator = L'\0';

    const wchar_t* arguments = skip_program_name(GetCommandLineW());

    static const wchar_t format[] = L"\"%ls\\python\\python.exe\" -I -B \"%ls\\lib\\psd-tools-cli.py\" %ls";
    size_t size = wcslen(format) + 2 * wcslen(bundle) + wcslen(arguments) + 1;
    wchar_t* command_line = (wchar_t*)HeapAlloc(GetProcessHeap(), 0, size * sizeof(wchar_t));
    if (command_line == NULL)
    {
        fwprintf(stderr, L"psd-tools: out of memory\n");
        return 1;
    }
    _snwprintf(command_line, size, format, bundle, bundle, arguments);
    command_line[size - 1] = L'\0';

    SetConsoleCtrlHandler(ignore_control_event, TRUE);

    STARTUPINFOW startup_info;
    PROCESS_INFORMATION process_info;
    ZeroMemory(&startup_info, sizeof(startup_info));
    startup_info.cb = sizeof(startup_info);
    ZeroMemory(&process_info, sizeof(process_info));
    if (!CreateProcessW(NULL, command_line, NULL, NULL, TRUE, 0, NULL, NULL, &startup_info, &process_info))
    {
        fwprintf(stderr, L"psd-tools: cannot start %ls\\python\\python.exe (error %lu)\n", bundle, GetLastError());
        return 1;
    }

    WaitForSingleObject(process_info.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process_info.hProcess, &exit_code);
    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
    return (int)exit_code;
}
