package org.s2arm.android;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.HashSet;
import java.util.Set;

/** The library never loads the native runtime. Each explicit launch is admitted again in :game. */
public final class LibraryActivity extends Activity {
    private GameLibrary library;
    private TextView status;
    // #528 item 15: "the last game session ended abnormally", once, above the status line; never blocks the library.
    private LinearLayout notice;
    private TextView noticeText;
    private LinearLayout more;
    private LibraryShelf shelf;
    private CheckBox fpsOverlay;
    private final Set<String> listed = new HashSet<>();
    private final java.util.Map<String, String> names = new java.util.HashMap<>();
    private final android.os.Handler ui = new android.os.Handler(android.os.Looper.getMainLooper());
    private static final int PICK_PACKAGE = 1, PICK_IN_PLACE = 2, ASK_LEGACY_READ = 3, SAVE_DIAGNOSTICS = 4;
    /** 原地使用的约定位置：文件夹选择器从这里打开（在的话）；deploy_game.py --in-place 也推到这下面。 */
    static final String IN_PLACE_DIR = "S2Arm/Games";
    // Bundle name waiting for the system file picker (kept across activity recreation).
    private String pendingSave;
    private static final String STATE_PENDING_SAVE = "pendingDiagnosticSave";
    // A caller opts in to consuming one direct child of files/import/.
    public static final String EXTRA_IMPORT_STAGING = "org.s2arm.android.IMPORT_STAGING";
    /** 电脑直传资源包（ImportReceiver）：开本地套接字 s2arm-import.&lt;包名&gt;，只收 adb（shell uid）连进来的一次传输。 */
    public static final String EXTRA_IMPORT_RECEIVE = "org.s2arm.android.IMPORT_RECEIVE";
    static final int SHELL_UID = 2000;          // adb forward 的连接由 adbd 发起，对端是 shell 用户
    static final int RECEIVE_WAIT_MS = 120000;  // 开着等电脑连进来的最长时间

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if (state != null) pendingSave = state.getString(STATE_PENDING_SAVE);
        // 与 iOS 同一个样子（shell/Sources/ShellUI/CoverFlowView.swift）：横屏封面流，点正中的卡片开始玩。
        //   导入 / 帧率显示 / 诊断包不在主页面：右上「游戏设置」「设置」两个圆钮打开右侧面板（iOS 的设置页还没整套搬过来，先放这三项）。
        float density = getResources().getDisplayMetrics().density;
        android.widget.FrameLayout root = new android.widget.FrameLayout(this);
        more = new LinearLayout(this); more.setOrientation(LinearLayout.VERTICAL); more.setVisibility(android.view.View.GONE);
        int pad = Math.round(20 * density);
        more.setPadding(pad, pad, pad, pad);
        more.setBackgroundColor(0xF01A1A1C);
        shelf = new LibraryShelf(this, new LibraryShelf.Listener() {
            @Override public void play(String titleId) { launch(titleId); }
            @Override public void openGameSettings() { toggleMore(); }
            @Override public void openControllers() { toggleMore(); }
            @Override public void openSettings() { toggleMore(); }
        });
        root.addView(shelf, new android.widget.FrameLayout.LayoutParams(-1, -1));
        Button importButton = new Button(this); importButton.setText(R.string.import_game);
        importButton.setOnClickListener(v -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_PACKAGE));
        more.addView(importButton);
        // 原地使用：游戏文件已经在手机存储里（文件管理器 / 电脑拷进去），直接用那里的，不再拷一份进 App
        Button inPlaceButton = new Button(this); inPlaceButton.setText(R.string.in_place_game);
        inPlaceButton.setOnClickListener(v -> useInPlace());
        more.addView(inPlaceButton);
        android.content.SharedPreferences display = getSharedPreferences("display", MODE_PRIVATE);
        fpsOverlay = new CheckBox(this);
        fpsOverlay.setText(R.string.fps_overlay_show);
        fpsOverlay.setTextColor(0xFFFFFFFF);
        fpsOverlay.setChecked(display.getBoolean("fps", false));
        fpsOverlay.setOnCheckedChangeListener((button, checked) -> {
            if (display.getBoolean("fps", false) != checked)
                display.edit().putBoolean("fps", checked).apply();
        });
        more.addView(fpsOverlay);
        // #528 item 15: works without any game; the bundle goes to whatever app the player picks.
        Button exportButton = new Button(this); exportButton.setText(R.string.export_diagnostics);
        exportButton.setOnClickListener(v -> exportDiagnostics(exportButton, false));
        more.addView(exportButton);
        // Some share sheets (Xiaomi's, for one) have no "save as file" target: the system file picker always does.
        Button saveButton = new Button(this); saveButton.setText(R.string.save_diagnostics);
        saveButton.setOnClickListener(v -> exportDiagnostics(saveButton, true));
        more.addView(saveButton);
        root.addView(more, new android.widget.FrameLayout.LayoutParams(Math.round(320 * density), -1, android.view.Gravity.END));
        // 状态区在底部：上一局异常结束的提示（有才显示），下面是状态行
        LinearLayout footer = new LinearLayout(this); footer.setOrientation(LinearLayout.VERTICAL);
        notice = new LinearLayout(this); notice.setOrientation(LinearLayout.VERTICAL); notice.setVisibility(android.view.View.GONE);
        notice.setPadding(pad, pad / 2, pad, pad / 2); notice.setBackgroundColor(0xE6332A12);
        noticeText = new TextView(this); noticeText.setTextColor(0xFFFFFFFF);
        notice.addView(noticeText);
        // 入口复用「更多」面板里的导出 / 保存：同一条路径、同一个按钮的忙碌状态
        LinearLayout noticeActions = new LinearLayout(this);
        Button noticeExport = new Button(this); noticeExport.setText(R.string.export_diagnostics);
        noticeExport.setOnClickListener(v -> { hideNotice(); exportDiagnostics(exportButton, false); });
        Button noticeSave = new Button(this); noticeSave.setText(R.string.save_diagnostics);
        noticeSave.setOnClickListener(v -> { hideNotice(); exportDiagnostics(saveButton, true); });
        Button noticeDismiss = new Button(this); noticeDismiss.setText(R.string.last_session_dismiss);
        noticeDismiss.setOnClickListener(v -> hideNotice());
        noticeActions.addView(noticeExport); noticeActions.addView(noticeSave); noticeActions.addView(noticeDismiss);
        notice.addView(noticeActions);
        footer.addView(notice);
        // 状态行只给玩家看得懂的：导入进度、失败原因；库清单（Games: 文件数 / 哈希…）只进日志，不上屏
        status = new TextView(this); status.setVisibility(android.view.View.GONE);
        status.setTextColor(0xFFFFFFFF); status.setPadding(pad, pad / 2, pad, pad / 2); status.setBackgroundColor(0xB3000000);
        footer.addView(status);
        root.addView(footer, new android.widget.FrameLayout.LayoutParams(-1, -2, android.view.Gravity.BOTTOM));
        setContentView(root);
        library = new GameLibrary(getApplicationContext(), new GameLibrary.Listener() {
            @Override public void onStatus(String text) { runOnUiThread(() -> {
                if (isDestroyed()) return;
                status.setText(text);
                status.setVisibility(text.startsWith("Games:") ? android.view.View.GONE : android.view.View.VISIBLE);
            }); }
            @Override public void onGameAvailable(String titleId, String name, java.io.File art) { runOnUiThread(() -> {
                if (isDestroyed() || !listed.add(titleId)) return;
                names.put(titleId, name);
                shelf.addGame(titleId, name, art);
            }); }
        });
    }

    private void toggleMore() {
        more.setVisibility(more.getVisibility() == android.view.View.GONE ? android.view.View.VISIBLE : android.view.View.GONE);
    }

    private void show(String text) { status.setText(text); status.setVisibility(android.view.View.VISIBLE); }

    // #528 item 15: the last game session died in the foreground (LastSession, the marker the :game process keeps).
    //   Asked once: the marker is cleared before the notice shows. Not while a game process lives (split screen can
    //   keep the game in front next to the library); "bg" or no marker never asks.
    private void checkLastSession() {
        java.io.File dir = getFilesDir();
        if (LastSession.read(dir) != LastSession.FOREGROUND || GameActivity.runningPid(this) != 0) return;
        long markedAt = LastSession.markedAt(dir);
        try { LastSession.mark(dir, LastSession.NONE); }
        catch (java.io.IOException | RuntimeException error) { android.util.Log.w("S2Arm", "Cannot clear the session mark", error); }
        android.content.Context app = getApplicationContext();
        new Thread(() -> {
            String text = LastSessionNotice.text(app, markedAt);   // a binder call for the exit reason: off the main thread
            runOnUiThread(() -> {
                if (isDestroyed()) return;
                noticeText.setText(text);
                notice.setVisibility(android.view.View.VISIBLE);
            });
        }, "s2a-last-session").start();
    }

    private void hideNotice() { notice.setVisibility(android.view.View.GONE); }

    private void launch(String titleId) { launch(titleId, 0); }

    // 不堵门：点的就是正在跑的那款 → 回到它；那款还在启动、收条没写出 → 等一会儿再回到它；
    //   正在跑的是别的款 → 问玩家要不要结束它（照常收局保存）再起这一款，而不是报「launch refused」
    private void launch(String titleId, int waited) {
        Intent options = new Intent(getIntent());
        options.removeExtra(GameResume.EXTRA);
        options.removeExtra(GameActivity.SWITCH_EXTRA);
        int pid = GameActivity.runningPid(this);
        if (pid != 0) {
            try {
                options.putExtra(GameResume.EXTRA,
                    GameResume.requireSame(getCacheDir(), pid, titleId, new java.io.File(getFilesDir(), "games")));
            } catch (java.io.IOException | BootContract.BadGame | RuntimeException notSame) {
                String active = GameResume.activeTitle(getCacheDir());
                if ((active == null || active.equals(titleId)) && waited < 20) {   // 还在启动：每 0.5 秒再看一次，最多 10 秒
                    show(getString(R.string.library_game_starting));
                    ui.postDelayed(() -> { if (!isDestroyed()) launch(titleId, waited + 1); }, 500);
                    return;
                }
                confirmSwitch(active, titleId);
                return;
            }
        }
        try {
            startActivity(GameActivity.launch(this, options, titleId));
        } catch (RuntimeException error) {
            status.setTextColor(0xFFFF5252);
            show(getString(R.string.library_launch_failed, String.valueOf(error.getMessage())));
        }
    }

    private String label(String titleId) {
        if (titleId == null) return getString(R.string.library_current_game);
        String name = names.get(titleId);
        return name != null ? name : titleId;
    }

    private void confirmSwitch(String active, String titleId) {
        new android.app.AlertDialog.Builder(this)
            .setTitle(R.string.library_switch_title)
            .setMessage(getString(R.string.library_switch_message, label(active), label(titleId)))
            .setPositiveButton(R.string.library_switch_confirm, (dialog, which) -> switchTo(active, titleId))
            .setNegativeButton(R.string.library_switch_cancel, null)
            .show();
    }

    // 让正在跑的那局正常收局（MainActivity.onNewIntent 认 SWITCH_EXTRA），等它的进程退出再起新款；20 秒还没退就如实说
    private void switchTo(String active, String titleId) {
        Intent stop = new Intent(getIntent());
        stop.removeExtra(GameResume.EXTRA);
        stop.putExtra(GameActivity.SWITCH_EXTRA, true);
        try {
            startActivity(GameActivity.launch(this, stop, titleId));
        } catch (RuntimeException error) {
            status.setTextColor(0xFFFF5252);
            show(getString(R.string.library_launch_failed, String.valueOf(error.getMessage())));
            return;
        }
        show(getString(R.string.library_switch_waiting, label(active)));
        waitThenLaunch(titleId, 0);
    }

    private void waitThenLaunch(String titleId, int tries) {
        if (isDestroyed()) return;
        if (GameActivity.runningPid(this) == 0) { launch(titleId); return; }
        if (tries >= 40) {
            status.setTextColor(0xFFFF5252);
            show(getString(R.string.library_switch_timeout));
            return;
        }
        ui.postDelayed(() -> waitThenLaunch(titleId, tries + 1), 500);
    }

    private void exportDiagnostics(Button button, boolean saveToFile) {
        button.setEnabled(false);
        show(getString(R.string.export_diagnostics_running));
        android.content.Context app = getApplicationContext();
        new Thread(() -> {
            java.nio.file.Path bundle = null;
            String error = null;
            try {
                bundle = DiagnosticExport.run(app);
            } catch (java.io.IOException | RuntimeException e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            }
            java.nio.file.Path done = bundle;
            String failure = error;
            runOnUiThread(() -> {
                if (isDestroyed()) return;
                button.setEnabled(true);
                if (done == null) {
                    show(getString(R.string.export_diagnostics_failed, failure));
                    return;
                }
                if (saveToFile) {
                    pendingSave = done.getFileName().toString();
                    Intent create = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                        .setType("application/zip").putExtra(Intent.EXTRA_TITLE, pendingSave);
                    startActivityForResult(create, SAVE_DIAGNOSTICS);
                    return;
                }
                android.net.Uri uri = DiagnosticShareProvider.uri(this, done);
                Intent send = new Intent(Intent.ACTION_SEND).setType("application/zip")
                    .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                send.setClipData(android.content.ClipData.newRawUri(done.getFileName().toString(), uri));
                show(getString(R.string.export_diagnostics_done, done.getFileName().toString()));
                startActivity(Intent.createChooser(send, getString(R.string.export_diagnostics)));
            });
        }, "s2a-diag-export").start();
    }

    @Override protected void onResume() {
        super.onResume();
        fpsOverlay.setChecked(getSharedPreferences("display", MODE_PRIVATE).getBoolean("fps", false));
        if (library != null) {
            boolean receive = getIntent().hasExtra(EXTRA_IMPORT_RECEIVE);
            getIntent().removeExtra(EXTRA_IMPORT_RECEIVE);
            String staging = getIntent().getStringExtra(EXTRA_IMPORT_STAGING);
            getIntent().removeExtra(EXTRA_IMPORT_STAGING); // do not repeat on later resumes
            if (receive) receiveImport(); else library.scanImports(staging);
        }
        checkLastSession();
    }
    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        if (pendingSave != null) state.putString(STATE_PENDING_SAVE, pendingSave);
    }

    /** Copies the exported bundle into the document the player created in the system file picker. */
    private void saveDiagnostics(android.net.Uri target, String name) {
        android.content.Context app = getApplicationContext();
        new Thread(() -> {
            String error = null;
            try {
                DiagnosticBundleWriter.saveBundle(DiagnosticShareProvider.directory(app), name,
                    mode -> app.getContentResolver().openOutputStream(target, mode));
            } catch (java.io.IOException | RuntimeException e) {
                error = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            }
            String failure = error;
            runOnUiThread(() -> {
                if (isDestroyed()) return;
                show(failure == null ? getString(R.string.save_diagnostics_done, name) : getString(R.string.save_diagnostics_failed, failure));
            });
        }, "s2a-diag-save").start();
    }

    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); }

    // 直传：本地套接字收一次资源包进私有 files/import/<名字>，收完照常 scanImports（按 index.tsv 逐文件核）。
    //   不经共享存储（FUSE）。只认 shell uid 的对端：别的 App 连进来直接断开、接着等
    private void receiveImport() {
        final GameLibrary lib = library;
        final String name = "s2arm-import." + getPackageName();
        final java.io.File parent = new java.io.File(getFilesDir(), "import");
        new Thread(() -> {
            android.net.LocalServerSocket server;
            try { server = new android.net.LocalServerSocket(name); }
            catch (java.io.IOException e) { android.util.Log.e("S2Arm", "Game import receiver: cannot listen on " + name + ": " + e.getMessage()); return; }
            final android.net.LocalServerSocket srv = server;
            Thread timer = new Thread(() -> {
                try { Thread.sleep(RECEIVE_WAIT_MS); srv.close(); } catch (InterruptedException | java.io.IOException ignored) { }
            }, "s2a-import-wait");
            timer.setDaemon(true); timer.start();
            android.util.Log.i("S2Arm", "Game import receiver listening: " + name);
            try {
                while (true) {
                    android.net.LocalSocket s;
                    try { s = srv.accept(); } catch (java.io.IOException closed) { android.util.Log.e("S2Arm", "Game import receiver: nobody connected"); return; }
                    try (android.net.LocalSocket c = s) {
                        if (c.getPeerCredentials().getUid() != SHELL_UID) {
                            android.util.Log.e("S2Arm", "Game import receiver: refused peer uid " + c.getPeerCredentials().getUid());
                            continue;
                        }
                        timer.interrupt();
                        long t0 = System.nanoTime();
                        ImportReceiver.Received got = ImportReceiver.receiveAny(c.getInputStream(), c.getOutputStream(), parent);
                        if (got.inPlace) {   // 电脑已把资源目录 adb push 到共享存储：原地登记，不传字节
                            android.util.Log.i("S2Arm", "Game in-place request: " + got.dir);
                            runOnUiThread(() -> lib.registerInPlace(got.dir));
                            return;
                        }
                        java.io.File dir = got.dir;
                        android.util.Log.i("S2Arm", "Game import received " + dir.getName() + " in " + (System.nanoTime() - t0) / 1000000 + " ms");
                        runOnUiThread(() -> lib.scanImports(dir.getAbsolutePath()));
                        return;
                    } catch (java.io.IOException e) {
                        android.util.Log.e("S2Arm", "Game import of requested directory refused: receive failed: " + e.getMessage());
                        return;
                    }
                }
            } finally {
                try { srv.close(); } catch (java.io.IOException ignored) { }
            }
        }, "s2a-import-receive").start();
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == PICK_PACKAGE && result == RESULT_OK && data != null && data.getData() != null) library.importTree(data.getData());
        if (request == PICK_IN_PLACE && result == RESULT_OK && data != null && data.getData() != null) {
            String path;
            try { path = GameLibrary.inPlacePath(android.provider.DocumentsContract.getTreeDocumentId(data.getData()),
                android.os.Environment.getExternalStorageDirectory()); }
            catch (IllegalArgumentException notTree) { path = null; }
            if (path == null) { status.setTextColor(0xFFFF5252); show(getString(R.string.in_place_not_local)); return; }
            library.registerInPlace(new java.io.File(path));
        }
        if (request == SAVE_DIAGNOSTICS) {
            String name = pendingSave;
            pendingSave = null;
            if (result == RESULT_OK && data != null && data.getData() != null && name != null) saveDiagnostics(data.getData(), name);
        }
    }

    // 原地使用：读共享存储上别处来的文件要「所有文件访问」（安卓 11+）；没开就说明并带去系统设置页
    //   （做法照 mamcjr/Swap2-Native MainActivity.needAccess / openAccessSettings，MIT）。安卓 10 走旧的读存储权限
    private void useInPlace() {
        if (android.os.Build.VERSION.SDK_INT >= 30 && !android.os.Environment.isExternalStorageManager()) {
            new android.app.AlertDialog.Builder(this)
                .setTitle(R.string.in_place_access_title)
                .setMessage(getString(R.string.in_place_access_text))
                .setPositiveButton(R.string.in_place_access_open, (dialog, which) -> openAllFilesAccess())
                .setNegativeButton(R.string.library_switch_cancel, null)
                .show();
            return;
        }
        if (android.os.Build.VERSION.SDK_INT < 30 && checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {android.Manifest.permission.READ_EXTERNAL_STORAGE}, ASK_LEGACY_READ);
            return;
        }
        pickInPlace();
    }

    private void openAllFilesAccess() {
        try {
            startActivity(new Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                android.net.Uri.parse("package:" + getPackageName())));
        } catch (RuntimeException noPerAppPage) {   // 个别系统没有按应用的那一页：打开总列表
            startActivity(new Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
        }
    }

    private void pickInPlace() {
        Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        if (new java.io.File(android.os.Environment.getExternalStorageDirectory(), IN_PLACE_DIR).isDirectory())
            pick.putExtra(android.provider.DocumentsContract.EXTRA_INITIAL_URI, android.net.Uri.parse(
                "content://com.android.externalstorage.documents/document/primary%3A" + IN_PLACE_DIR.replace("/", "%2F")));
        startActivityForResult(pick, PICK_IN_PLACE);
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == ASK_LEGACY_READ && results.length == 1 && results[0] == android.content.pm.PackageManager.PERMISSION_GRANTED)
            pickInPlace();
    }
    @Override protected void onDestroy() { if (library != null) library.close(); super.onDestroy(); }
}
