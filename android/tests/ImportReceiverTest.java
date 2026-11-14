package org.s2arm.android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;

/** 资源包直传接收（ImportReceiver）：协议、路径防越界、收不全不落地。期望按协议手算。 */
public final class ImportReceiverTest {
    private static int failures, checks;
    private static void check(boolean ok, String what) { checks++; if (!ok) { failures++; System.err.println("FAIL: " + what); } }

    private static byte[] stream(String... parts) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        for (String p : parts) b.write(p.getBytes(StandardCharsets.ISO_8859_1));
        return b.toByteArray();
    }

    public static void main(String[] args) throws Exception {
        File parent = Files.createTempDirectory("s2a-recv").toFile();
        // ① 正常：两个文件（一个空），收完改名成 parent/pkg，回 READY 再回 OK 2 5
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        File done = ImportReceiver.receive(new ByteArrayInputStream(stream(
            "S2A-IMPORT 1 pkg\n", "F 5 a/b.bin\n", "hello", "F 0 empty\n", "END\n")), out, parent);
        check(done.equals(new File(parent, "pkg")), "lands at parent/pkg");
        check(Arrays.equals(Files.readAllBytes(new File(done, "a/b.bin").toPath()), "hello".getBytes()), "content byte-exact");
        check(new File(done, "empty").isFile() && new File(done, "empty").length() == 0, "empty file kept");
        check(out.toString().equals("READY 1\nOK 2 5\n"), "replies READY then OK (" + out + ")");
        check(!new File(parent, ".pkg.part").exists(), "no .part left");

        // ② 越界路径：拒，回 ERR，不留临时目录，不落 parent/evil
        for (String bad : new String[] {"../x", "/abs", "a//b", "a/./b", "a\\b"}) {
            out = new ByteArrayOutputStream(); String err = "";
            try { ImportReceiver.receive(new ByteArrayInputStream(stream("S2A-IMPORT 1 evil\n", "F 1 " + bad + "\n", "x", "END\n")), out, parent); }
            catch (IOException e) { err = e.getMessage(); }
            check(err.startsWith("bad path"), "refuses path " + bad + " (" + err + ")");
            check(out.toString().startsWith("READY 1\nERR bad path"), "replies ERR for " + bad);
            check(!new File(parent, "evil").exists() && !new File(parent, ".evil.part").exists(), "nothing left for " + bad);
        }

        // ③ 流在文件中途断：拒，不落地，旧的 parent/pkg 不被替换
        out = new ByteArrayOutputStream(); String err = "";
        try { ImportReceiver.receive(new ByteArrayInputStream(stream("S2A-IMPORT 1 pkg\n", "F 10 a/b.bin\n", "abc")), out, parent); }
        catch (IOException e) { err = e.getMessage(); }
        check(err.contains("stream ended"), "truncated stream refused (" + err + ")");
        check(Arrays.equals(Files.readAllBytes(new File(parent, "pkg/a/b.bin").toPath()), "hello".getBytes()), "previous package untouched");

        // ④ 名字不合法 / 头不对：拒
        for (String head : new String[] {"S2A-IMPORT 1 ../up\n", "S2A-IMPORT 2 pkg\n", "HELLO\n"}) {
            err = "";
            try { ImportReceiver.receive(new ByteArrayInputStream(stream(head, "END\n")), new ByteArrayOutputStream(), parent); }
            catch (IOException e) { err = e.getMessage(); }
            check(!err.isEmpty(), "refuses header " + head.trim());
        }
        GameInstall.deleteTree(parent);
        if (failures > 0) { System.err.println(failures + " / " + checks + " failed"); System.exit(1); }
        System.out.println("ImportReceiver: ok (" + checks + " checks)");
    }
}
