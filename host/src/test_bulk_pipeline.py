"""Exercise Host BULK_WRITE using a recording transport, without a board.

Runs 3 builds x 5 commands x 16 groups in both byte-identical send modes.
Loopback framing remains real; arithmetic is known-answer synthetic replay.
"""
import fake_board
import host
import link
import unpack
import vectors


class RecordingLink(link.LoopbackLink):
    def __init__(self, board, bulk):
        super().__init__(board)
        self.BULK_WRITE=bulk
        self.writes=[]

    def write(self,data):
        self.writes.append(bytes(data))
        return super().write(data)


def main():
    # Exercise the production SerialLink.write adapter itself with a recording
    # byte sink. No serial constructor, driver or electrical timing is involved.
    class SerialSink:
        def __init__(self):self.chunks=[];self.flushes=0
        def write(self,data):self.chunks.append(data);return len(data)
        def flush(self):self.flushes+=1
    serial_adapter=link.SerialLink.__new__(link.SerialLink)
    for n in (256,512):
        sink=SerialSink();serial_adapter._ser=sink
        payload=b'123\n'*n
        serial_adapter.write(payload)
        assert sink.chunks==[payload] and sink.flushes==0
    transactions=0
    for pe in (1,4,16):
        for key,(files,exp_file) in vectors.VECTORS.items():
            inputs=[vectors.split_groups(vectors.read_vector(vectors.BATCH_DIR/f),f) for f in files]
            gold=vectors.split_groups(vectors.read_vector(vectors.BATCH_DIR/exp_file),exp_file)
            command=' '.join(key)+' 1'
            paths=[]
            for bulk in (False,True):
                bd=fake_board.FakeBoard(build=pe,physical_order=True)
                lk=RecordingLink(bd,bulk)
                h=host.Host(lk)
                assert h.handshake() and h.build==pe
                outcomes=[]
                for g in range(16):
                    data=[rows[g][i] for bank,rows in enumerate(inputs)
                          for i in unpack.load_permutation(key,bank,pe)]
                    lk.writes.clear()
                    txn=h.run(command,data,expect_rows=256)
                    assert txn.outcome==host.RESULT_OK,txn.summary()
                    assert txn.attempts==1 and not bd.mismatches
                    actual=unpack.unpack(unpack.kind_of(command),txn.rows,pe)
                    assert actual==[int(x,16) for x in gold[g]]
                    chunks=list(lk.writes)
                    assert len(chunks)==(2 if bulk else 1+len(data)), (pe,command,len(chunks))
                    expected_data=''.join(s+'\n' for s in data).encode('ascii')
                    assert b''.join(chunks[1:])==expected_data
                    if bulk: assert chunks[1]==expected_data
                    assert b'\r' not in b''.join(chunks)
                    assert b''.join(txn.sent_bytes)==b''.join(chunks)
                    assert len(txn.sent_bytes)==1+len(data) # logical per-line audit retained
                    outcomes.append((b''.join(chunks),actual,txn.attempts))
                    transactions+=1
                paths.append(outcomes)
                lk.close()
            assert paths[0]==paths[1],(pe,command,'bulk stream/results differ')
            print(f'BULK pe{pe} {command}: 16 pairs byte/result-identical; 1 data write vs {len(data)}',flush=True)
    # A bad coefficient is still rejected when the bulk path is enabled.
    lk=RecordingLink(fake_board.FakeBoard(build=1,physical_order=True),True)
    h=host.Host(lk);h.handshake()
    data=vectors.read_vector(vectors.BATCH_DIR/'ntt_batch_in.txt')[:256]
    data[0]=f'{(int(data[0],16)+1)%3329:03x}'
    try:
        h.run('#NTT 1',data,expect_rows=256)
    except ValueError as exc:
        assert 'no exact input vector' in str(exc)
    else:raise AssertionError('damaged bulk data accepted')
    finally:lk.close()
    print(f'PASS: {transactions} transactions (240 bulk + 240 line), 122880 coefficients; bad bulk input rejected.')
    print('PASS: production SerialLink.write with recording byte sink: one write and zero flushes per 256/512-row block.')
    print('Scope: Host bulk branch/framing/layout; no USB timing, real serial or RTL arithmetic proof.')

if __name__=='__main__':main()
