"""Standard intrinsic handleOps calldata rule, with maximally priced op values."""

def reserve_pvg(lengths):
    word = lambda n: n.to_bytes(32, 'big')
    dynamic = ('initCode', 'callData', 'paymasterAndData', 'signature')
    tails = {}
    offset = 9 * 32
    for field in dynamic:
        n = lengths[field]
        if type(n) is not int or n < 0:
            raise ValueError('PVG_LENGTHS')
        tail = word(n) + b'\xff' * n + b'\0' * (-n % 32)
        tails[field] = (word(offset), tail)
        offset += len(tail)
    head = b'\0' * 12 + b'\xff' * 20 + b'\xff' * 32
    head += tails['initCode'][0] + tails['callData'][0]
    head += b'\xff' * 96
    head += tails['paymasterAndData'][0] + tails['signature'][0]
    # handleOps selector, argument offset, maximal beneficiary, array length, tuple offset.
    data = bytes.fromhex('765e827f') + word(64) + b'\0' * 12 + b'\xff' * 20 + word(1) + word(32)
    data += head + b''.join(tails[k][1] for k in dynamic)
    return 21000 + sum(4 if b == 0 else 16 for b in data)
