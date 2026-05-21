import argparse
import asyncio
import bruteratel

async def writeShellcode(wsClient, config, arch, evasion, type, exitmethod):
    shellcode = await bruteratel.br_build_badger(wsClient, config, arch, evasion, type, exitmethod)
    if shellcode is not None:
        shellcodeLen = len(shellcode)
        print(f"[+] Received shellcode of {shellcodeLen} bytes")
        fileIO = open(bruteratel.g_BADGER_OUTPUT_NAME, "wb")
        bytesWritten = fileIO.write(shellcode)
        fileIO.close()
        print("[+] Wrote %d bytes to disk" % bytesWritten)
    else:
        print("[-] Error building badger")

async def main():
    parser = argparse.ArgumentParser(
        description="Build a stageless badger shellcode from a provided configuration. The (-dump) argument dumps all badgers shellcode and does not need any extra evasion/type arguments",
        epilog="Example:\n" \
        " python3 api_build_badger.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -profile primary-c2 -dump\n" \
        " python3 api_build_badger.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -profile primary-c2 -arch x64 -evasion etw -type full -method rtl\n" \
        " python3 api_build_badger.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -profile primary-c2 -arch x86 -evasion etw -type full -method rtl\n" \
        " python3 api_build_badger.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -profile primary-c2 -arch x64 -evasion stealth -type min-bin -method rtl",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str,            required=True,  help="api server username", metavar='')
    parser.add_argument('-password', type=str,            required=True,  help="api server password", metavar='')
    parser.add_argument('-handler',  type=str,            required=True,  help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-profile',  type=str,            required=True,  help="profile/listener name. Eg: primary-c2", metavar='')
    parser.add_argument('-dump',     action='store_true', required=False, help="Dump all badger shellcodes")
    parser.add_argument('-arch',     type=str,            required=False, help="Badger architecture. Eg.: x86/x64", metavar='')
    parser.add_argument('-evasion',  type=str,            required=False, help="Badger's evasion type: etw, stealth", metavar='')
    parser.add_argument('-type',     type=str,            required=False, help="Badger's type: full, min-bin, net-bin", metavar='')
    parser.add_argument('-method',   type=str,            required=False, help="Badger's exit-method: rtl, wait", metavar='')
    args = parser.parse_args()

    if not args.dump:
        if not (args.arch and args.evasion and args.type and args.method):
            parser.error("Either (-d) or (-a -e, -t and -m) is required")

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    if args.dump:
        # x86 build
        await writeShellcode(wsClient, args.profile, "x86", "etw", "full", "rtl")
        await writeShellcode(wsClient, args.profile, "x86", "etw", "full", "wait")
        await writeShellcode(wsClient, args.profile, "x86", "etw", "min-bin", "rtl")
        await writeShellcode(wsClient, args.profile, "x86", "etw", "min-bin", "wait")
        await writeShellcode(wsClient, args.profile, "x86", "etw", "net-bin", "rtl")
        await writeShellcode(wsClient, args.profile, "x86", "etw", "net-bin", "wait")
        # x64 build - etw
        await writeShellcode(wsClient, args.profile, "x64", "etw", "full", "rtl")
        await writeShellcode(wsClient, args.profile, "x64", "etw", "full", "wait")
        await writeShellcode(wsClient, args.profile, "x64", "etw", "min-bin", "rtl")
        await writeShellcode(wsClient, args.profile, "x64", "etw", "min-bin", "wait")
        await writeShellcode(wsClient, args.profile, "x64", "etw", "net-bin", "rtl")
        await writeShellcode(wsClient, args.profile, "x64", "etw", "net-bin", "wait")
        # x64 build - stealth
        await writeShellcode(wsClient, args.profile, "x64", "stealth", "full", "rtl")
        await writeShellcode(wsClient, args.profile, "x64", "stealth", "full", "wait")
        await writeShellcode(wsClient, args.profile, "x64", "stealth", "min-bin", "rtl")
        await writeShellcode(wsClient, args.profile, "x64", "stealth", "min-bin", "wait")
        await writeShellcode(wsClient, args.profile, "x64", "stealth", "net-bin", "rtl")
        await writeShellcode(wsClient, args.profile, "x64", "stealth", "net-bin", "wait")
    else:
        await writeShellcode(wsClient, args.profile, args.arch, args.evasion, args.type, args.method)

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
