import socket, struct, os, sys, threading
TFTP_ROOT = '/tmp/tftp'
def handle_rrq(addr, filename):
    xsock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    xsock.bind(('0.0.0.0', 0))
    filepath = os.path.join(TFTP_ROOT, filename)
    if not os.path.exists(filepath):
        xsock.sendto(struct.pack('!HH', 5, 1) + b'Not found\0', addr)
        print(f'File not found: {filename}')
        return
    size = os.path.getsize(filepath)
    print(f'Sending {filename} ({size} bytes)...')
    sys.stdout.flush()
    with open(filepath, 'rb') as f:
        block = 1
        while True:
            data = f.read(512)
            pkt = struct.pack('!HH', 3, block) + data
            for r in range(5):
                xsock.sendto(pkt, addr)
                xsock.settimeout(5)
                try:
                    resp, _ = xsock.recvfrom(1024)
                    if struct.unpack('!H', resp[2:4])[0] == block:
                        break
                except:
                    continue
            else:
                print('Transfer failed')
                return
            if len(data) < 512:
                print('Transfer complete!')
                return
            block += 1
            if block % 2000 == 0:
                print(f'  {block*512//1024}KB / {size//1024}KB sent...')
                sys.stdout.flush()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('0.0.0.0', 69))
print('TFTP server ready on port 69, serving from /tmp/tftp')
sys.stdout.flush()
while True:
    data, addr = sock.recvfrom(1024)
    if struct.unpack('!H', data[:2])[0] == 1:
        fn = data[2:].split(b'\0')[0].decode()
        print(f'Request: {fn} from {addr}')
        sys.stdout.flush()
        threading.Thread(target=handle_rrq, args=(addr, fn), daemon=True).start()
