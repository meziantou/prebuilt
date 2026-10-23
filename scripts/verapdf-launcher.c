/*
 * verapdf.exe, the launcher of the veraPDF bundle on Windows (see
 * scripts/build-verapdf.sh): it runs the Java runtime of the bundle with the
 * command line of the veraPDF CLI script, followed by its own arguments as it
 * received them, and exits with the exit code of Java.
 *
 *   <bundle>\verapdf.exe
 *   <bundle>\runtime\bin\java.exe
 *   <bundle>\lib\verapdf-cli.jar
 *
 * A .bat or .cmd launcher would go through cmd.exe, which parses the
 * arguments again (%, ^, &, quotes): this one passes the rest of its own
 * command line to Java untouched.
 *
 * Built with llvm-mingw: x86_64-w64-mingw32-clang -municode -O2 -static.
 */

#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define MAIN_CLASS L"org.verapdf.apps.GreenfieldCliWrapper"

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

/* Ctrl+C reaches every process of the console: veraPDF handles it, and the
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
        fwprintf(stderr, L"verapdf: cannot get the path of the launcher\n");
        return 1;
    }

    wchar_t* separator = wcsrchr(bundle, L'\\');
    if (separator == NULL)
    {
        fwprintf(stderr, L"verapdf: unexpected launcher path %ls\n", bundle);
        return 1;
    }
    *separator = L'\0';

    const wchar_t* arguments = skip_program_name(GetCommandLineW());

    static const wchar_t format[] =
        L"\"%ls\\runtime\\bin\\java.exe\" -Dfile.encoding=UTF8 -Djava.awt.headless=true -XX:+IgnoreUnrecognizedVMOptions "
        L"\"-Dapp.name=VeraPDF validation CLI\" \"-Dapp.home=%ls\" \"-Dbasedir=%ls\" "
        L"--add-exports=java.base/sun.security.pkcs=ALL-UNNAMED "
        L"-classpath \"%ls\\lib\\verapdf-cli.jar\" " MAIN_CLASS L" %ls";
    size_t size = wcslen(format) + 4 * wcslen(bundle) + wcslen(arguments) + 1;
    wchar_t* command_line = (wchar_t*)HeapAlloc(GetProcessHeap(), 0, size * sizeof(wchar_t));
    if (command_line == NULL)
    {
        fwprintf(stderr, L"verapdf: out of memory\n");
        return 1;
    }
    _snwprintf(command_line, size, format, bundle, bundle, bundle, bundle, arguments);
    command_line[size - 1] = L'\0';

    SetConsoleCtrlHandler(ignore_control_event, TRUE);

    STARTUPINFOW startup_info;
    PROCESS_INFORMATION process_info;
    ZeroMemory(&startup_info, sizeof(startup_info));
    startup_info.cb = sizeof(startup_info);
    ZeroMemory(&process_info, sizeof(process_info));
    if (!CreateProcessW(NULL, command_line, NULL, NULL, TRUE, 0, NULL, NULL, &startup_info, &process_info))
    {
        fwprintf(stderr, L"verapdf: cannot start %ls\\runtime\\bin\\java.exe (error %lu)\n", bundle, GetLastError());
        return 1;
    }

    WaitForSingleObject(process_info.hProcess, INFINITE);
    DWORD exit_code = 1;
    GetExitCodeProcess(process_info.hProcess, &exit_code);
    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
    return (int)exit_code;
}
