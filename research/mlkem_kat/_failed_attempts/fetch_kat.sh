#!/bin/bash
SHA=857a27312a02dc02cfd4d81119f2e601a4ea4a6a
URL="https://api.github.com/repos/post-quantum-cryptography/KAT/git/blobs/$SHA"
TOTAL=12012890; CHUNK=200000
rm -rf parts && mkdir -p parts
off=0; i=0
while [ $off -lt $TOTAL ]; do
  end=$((off+CHUNK-1)); [ $end -ge $TOTAL ] && end=$((TOTAL-1))
  exp=$((end-off+1))
  for try in 1 2 3 4 5; do
    curl -s --max-time 60 -H "Accept: application/vnd.github.raw" \
         -H "Range: bytes=$off-$end" "$URL" -o "parts/$(printf %04d $i)"
    got=$(stat -c%s "parts/$(printf %04d $i)" 2>/dev/null || echo 0)
    [ "$got" = "$exp" ] && break
    sleep 1
  done
  [ "$got" != "$exp" ] && echo "CHUNK_FAIL $i $got/$exp"
  off=$((end+1)); i=$((i+1))
  [ $((i % 10)) -eq 0 ] && echo "PROGRESS $i chunks, $off/$TOTAL bytes"
done
cat parts/* > kat_MLKEM_768.rsp && rm -rf parts
echo "DONE size=$(stat -c%s kat_MLKEM_768.rsp) count=$(grep -c '^count = ' kat_MLKEM_768.rsp) ssn=$(grep -c '^ss_n = ' kat_MLKEM_768.rsp)"
