package com.mounsokdara.video_player.accessibility.livecaption;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Map;

public final class TarBz2 {
    private TarBz2() {}

    public interface Cancel {
        boolean isCancelled();
    }

    public static int extract(File archive, Map<String, File> wanted, Cancel cancel) throws IOException {
        int written = 0;
        try (InputStream in = new Bzip2(new BufferedInputStream(new FileInputStream(archive), 1 << 16))) {
            byte[] hdr = new byte[512];
            byte[] buf = new byte[1 << 16];
            while (true) {
                if (!readFully(in, hdr, 512)) break;
                boolean zero = true;
                for (int i = 0; i < 512; i++) {
                    if (hdr[i] != 0) { zero = false; break; }
                }
                if (zero) break;
                String name = cstr(hdr, 0, 100);
                boolean ustar = hdr[257] == 'u' && hdr[258] == 's' && hdr[259] == 't' && hdr[260] == 'a' && hdr[261] == 'r';
                if (ustar) {
                    String prefix = cstr(hdr, 345, 155);
                    if (!prefix.isEmpty()) name = prefix + "/" + name;
                }
                long size = octal(hdr, 124, 12);
                char type = (char) hdr[156];
                while (name.startsWith("./")) name = name.substring(2);
                File dest = (type == '0' || type == 0) ? wanted.get(name) : null;
                long left = size;
                if (dest != null) {
                    File parent = dest.getParentFile();
                    if (parent != null) parent.mkdirs();
                    File part = new File(dest.getPath() + ".part");
                    try (OutputStream out = new FileOutputStream(part)) {
                        while (left > 0) {
                            if (cancel != null && cancel.isCancelled()) throw new IOException("cancelled");
                            int n = in.read(buf, 0, (int) Math.min(buf.length, left));
                            if (n < 0) throw new IOException("Archive ended early");
                            out.write(buf, 0, n);
                            left -= n;
                        }
                    }
                    if (dest.exists()) dest.delete();
                    if (!part.renameTo(dest)) throw new IOException("Could not save " + dest.getName());
                    written++;
                } else {
                    while (left > 0) {
                        if (cancel != null && cancel.isCancelled()) throw new IOException("cancelled");
                        int n = in.read(buf, 0, (int) Math.min(buf.length, left));
                        if (n < 0) throw new IOException("Archive ended early");
                        left -= n;
                    }
                }
                long pad = (512 - (size % 512)) % 512;
                while (pad > 0) {
                    long s = in.skip(pad);
                    if (s <= 0) {
                        if (in.read() < 0) break;
                        s = 1;
                    }
                    pad -= s;
                }
                if (written == wanted.size()) break;
            }
        }
        return written;
    }

    private static boolean readFully(InputStream in, byte[] b, int len) throws IOException {
        int off = 0;
        while (off < len) {
            int n = in.read(b, off, len - off);
            if (n < 0) return off != 0 && off == len;
            off += n;
        }
        return true;
    }

    private static String cstr(byte[] b, int off, int len) {
        int end = off;
        while (end < off + len && b[end] != 0) end++;
        return new String(b, off, end - off, java.nio.charset.StandardCharsets.UTF_8);
    }

    private static long octal(byte[] b, int off, int len) {
        long v = 0;
        for (int i = off; i < off + len; i++) {
            int c = b[i];
            if (c == 0 || c == ' ') {
                if (v == 0 && c == ' ') continue;
                break;
            }
            if (c < '0' || c > '7') break;
            v = (v << 3) + (c - '0');
        }
        return v;
    }

    static final class Bzip2 extends InputStream {
        private static final int MAX_CODE_LEN = 23;
        private static final int RUNA = 0;
        private static final int RUNB = 1;

        private final InputStream in;
        private long bitBuf;
        private int bitCnt;
        private int blockSize100k;
        private int[] tt;
        private int nblock;
        private int blockPos;
        private int tPos;
        private int lastCh = -1;
        private int runLen;
        private int repeat;
        private boolean streamOpen;
        private boolean finished;

        Bzip2(InputStream in) {
            this.in = in;
        }

        private int bits(int n) throws IOException {
            while (bitCnt < n) {
                int b = in.read();
                if (b < 0) throw new IOException("bzip2 data ended early");
                bitBuf = (bitBuf << 8) | b;
                bitCnt += 8;
            }
            int v = (int) ((bitBuf >>> (bitCnt - n)) & ((1L << n) - 1));
            bitCnt -= n;
            return v;
        }

        private int bit() throws IOException {
            return bits(1);
        }

        private boolean openStream() throws IOException {
            bitCnt = 0;
            bitBuf = 0;
            int b = in.read();
            if (b < 0) return false;
            int z = in.read();
            int h = in.read();
            int lv = in.read();
            if (b != 'B' || z != 'Z' || h != 'h' || lv < '1' || lv > '9') throw new IOException("Not bzip2 data");
            blockSize100k = lv - '0';
            if (tt == null || tt.length < blockSize100k * 100000) tt = new int[blockSize100k * 100000];
            return true;
        }

        private boolean nextBlock() throws IOException {
            while (true) {
                if (!streamOpen) {
                    if (!openStream()) return false;
                    streamOpen = true;
                }
                long magic = ((long) bits(24) << 24) | bits(24);
                if (magic == 0x314159265359L) {
                    readBlock();
                    return true;
                } else if (magic == 0x177245385090L) {
                    bits(32);
                    streamOpen = false;
                    bitCnt = 0;
                    bitBuf = 0;
                } else {
                    throw new IOException("bzip2 block header is wrong");
                }
            }
        }

        private void readBlock() throws IOException {
            bits(32);
            if (bit() != 0) throw new IOException("Randomised bzip2 blocks are not supported");
            int origPtr = bits(24);

            boolean[] inUse16 = new boolean[16];
            for (int i = 0; i < 16; i++) inUse16[i] = bit() == 1;
            byte[] seqToUnseq = new byte[256];
            int nInUse = 0;
            for (int i = 0; i < 16; i++) {
                if (!inUse16[i]) continue;
                for (int j = 0; j < 16; j++) {
                    if (bit() == 1) seqToUnseq[nInUse++] = (byte) (i * 16 + j);
                }
            }
            if (nInUse == 0) throw new IOException("bzip2 block has no symbols");
            int alphaSize = nInUse + 2;

            int nGroups = bits(3);
            if (nGroups < 2 || nGroups > 6) throw new IOException("bzip2 table count is wrong");
            int nSelectors = bits(15);
            if (nSelectors < 1) throw new IOException("bzip2 selector count is wrong");
            byte[] selector = new byte[nSelectors];
            byte[] pos = new byte[nGroups];
            for (int i = 0; i < nGroups; i++) pos[i] = (byte) i;
            for (int i = 0; i < nSelectors; i++) {
                int j = 0;
                while (bit() == 1) {
                    j++;
                    if (j >= nGroups) throw new IOException("bzip2 selector is wrong");
                }
                byte v = pos[j];
                while (j > 0) {
                    pos[j] = pos[j - 1];
                    j--;
                }
                pos[0] = v;
                selector[i] = v;
            }

            int[][] limit = new int[nGroups][MAX_CODE_LEN];
            int[][] base = new int[nGroups][MAX_CODE_LEN];
            int[][] perm = new int[nGroups][258];
            int[] minLens = new int[nGroups];
            for (int t = 0; t < nGroups; t++) {
                int[] len = new int[alphaSize];
                int curr = bits(5);
                for (int i = 0; i < alphaSize; i++) {
                    while (true) {
                        if (curr < 1 || curr > 20) throw new IOException("bzip2 code length is wrong");
                        if (bit() == 0) break;
                        curr += bit() == 0 ? 1 : -1;
                    }
                    len[i] = curr;
                }
                int minLen = 32;
                int maxLen = 0;
                for (int i = 0; i < alphaSize; i++) {
                    if (len[i] > maxLen) maxLen = len[i];
                    if (len[i] < minLen) minLen = len[i];
                }
                createDecodeTables(limit[t], base[t], perm[t], len, minLen, maxLen, alphaSize);
                minLens[t] = minLen;
            }

            int eob = nInUse + 1;
            int limitBlock = blockSize100k * 100000;
            int[] yy = new int[256];
            for (int i = 0; i < nInUse; i++) yy[i] = i;
            int[] unzftab = new int[256];
            int groupNo = -1;
            int groupPos = 0;
            int t = 0;
            nblock = 0;

            int sym = 0;
            boolean haveSym = false;
            while (true) {
                if (!haveSym) {
                    if (groupPos == 0) {
                        groupNo++;
                        if (groupNo >= nSelectors) throw new IOException("bzip2 ran out of selectors");
                        groupPos = 50;
                        t = selector[groupNo];
                    }
                    groupPos--;
                    sym = decodeSym(t, limit[t], base[t], perm[t], minLens[t]);
                }
                haveSym = false;
                if (sym == eob) break;
                if (sym == RUNA || sym == RUNB) {
                    int es = -1;
                    int n = 1;
                    do {
                        if (sym == RUNA) es += n;
                        else es += 2 * n;
                        n <<= 1;
                        if (n > (1 << 22)) throw new IOException("bzip2 run is too long");
                        if (groupPos == 0) {
                            groupNo++;
                            if (groupNo >= nSelectors) throw new IOException("bzip2 ran out of selectors");
                            groupPos = 50;
                            t = selector[groupNo];
                        }
                        groupPos--;
                        sym = decodeSym(t, limit[t], base[t], perm[t], minLens[t]);
                    } while (sym == RUNA || sym == RUNB);
                    es++;
                    int uc = seqToUnseq[yy[0]] & 0xff;
                    unzftab[uc] += es;
                    if (nblock + es > limitBlock) throw new IOException("bzip2 block is too big");
                    while (es-- > 0) tt[nblock++] = uc;
                    haveSym = true;
                    continue;
                }
                if (nblock >= limitBlock) throw new IOException("bzip2 block is too big");
                int nn = sym - 1;
                int uc = yy[nn];
                System.arraycopy(yy, 0, yy, 1, nn);
                yy[0] = uc;
                int ch = seqToUnseq[uc] & 0xff;
                unzftab[ch]++;
                tt[nblock++] = ch;
            }

            if (origPtr < 0 || origPtr >= nblock) throw new IOException("bzip2 start pointer is wrong");

            int[] cftab = new int[257];
            for (int i = 1; i <= 256; i++) cftab[i] = cftab[i - 1] + unzftab[i - 1];
            for (int i = 0; i < nblock; i++) {
                int uc = tt[i] & 0xff;
                tt[cftab[uc]] |= i << 8;
                cftab[uc]++;
            }
            tPos = tt[origPtr] >>> 8;
            blockPos = 0;
            lastCh = -1;
            runLen = 0;
            repeat = 0;
        }

        private int decodeSym(int t, int[] limit, int[] base, int[] perm, int minLen) throws IOException {
            int zn = minLen;
            int zvec = bits(zn);
            while (true) {
                if (zn > 20) throw new IOException("bzip2 code is wrong");
                if (zvec <= limit[zn]) break;
                zn++;
                zvec = (zvec << 1) | bit();
            }
            int idx = zvec - base[zn];
            if (idx < 0 || idx >= 258) throw new IOException("bzip2 code is wrong");
            return perm[idx];
        }

        private static void createDecodeTables(int[] limit, int[] base, int[] perm, int[] length, int minLen, int maxLen, int alphaSize) {
            int pp = 0;
            for (int i = minLen; i <= maxLen; i++) {
                for (int j = 0; j < alphaSize; j++) {
                    if (length[j] == i) perm[pp++] = j;
                }
            }
            for (int i = 0; i < MAX_CODE_LEN; i++) base[i] = 0;
            for (int i = 0; i < alphaSize; i++) base[length[i] + 1]++;
            for (int i = 1; i < MAX_CODE_LEN; i++) base[i] += base[i - 1];
            for (int i = 0; i < MAX_CODE_LEN; i++) limit[i] = 0;
            int vec = 0;
            for (int i = minLen; i <= maxLen; i++) {
                vec += base[i + 1] - base[i];
                limit[i] = vec - 1;
                vec <<= 1;
            }
            for (int i = minLen + 1; i <= maxLen; i++) {
                base[i] = ((limit[i - 1] + 1) << 1) - base[i];
            }
        }

        private int nextByte() throws IOException {
            while (true) {
                if (repeat > 0) {
                    repeat--;
                    return lastCh;
                }
                if (blockPos >= nblock) {
                    if (finished) return -1;
                    if (!nextBlock()) {
                        finished = true;
                        return -1;
                    }
                    continue;
                }
                tPos = tt[tPos];
                int ch = tPos & 0xff;
                tPos >>>= 8;
                blockPos++;
                if (runLen == 4) {
                    repeat = ch;
                    runLen = 0;
                    continue;
                }
                if (ch == lastCh && runLen > 0) {
                    runLen++;
                } else {
                    runLen = 1;
                    lastCh = ch;
                }
                return ch;
            }
        }

        @Override
        public int read() throws IOException {
            return nextByte();
        }

        @Override
        public int read(byte[] b, int off, int len) throws IOException {
            if (len == 0) return 0;
            int n = 0;
            while (n < len) {
                int c = nextByte();
                if (c < 0) break;
                b[off + n++] = (byte) c;
            }
            return n == 0 ? -1 : n;
        }

        @Override
        public void close() throws IOException {
            in.close();
        }
    }
}
