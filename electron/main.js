// Motionity desktop shell.
//
// The renderer is loaded over http://127.0.0.1 rather than file:// on purpose:
// the exporter needs WebCodecs (VideoEncoder) and project storage needs
// IndexedDB, and Chromium gates both behind a secure context. A loopback
// origin qualifies; file:// does not.

const { app, BrowserWindow, Menu, shell, session } = require('electron');
const path = require('node:path');
const { startServer: start } = require('../scripts/server.cjs');

// Electron's fs shim reads through the asar archive, so the same path works
// in development and in a packaged build.
const appRoot = path.join(__dirname, '..', 'src');

let serverUrl = null;
let httpServer = null;

async function startServer() {
  const { server, url } = await start({
    root: appRoot,
    host: '127.0.0.1',
    port: 0,
  });
  httpServer = server;
  serverUrl = url;
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1100,
    minHeight: 700,
    backgroundColor: '#141629',
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // The editor builds its ffmpeg worker from a blob: URL.
      webSecurity: true,
    },
  });

  win.once('ready-to-show', () => win.show());
  win.loadURL(serverUrl);

  // Pixabay/sponsor links are target="_blank"; send them to the real browser
  // instead of opening a chrome-less Electron window.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith(serverUrl)) {
      event.preventDefault();
      if (/^https?:/.test(url)) shell.openExternal(url);
    }
  });

  return win;
}

function buildMenu() {
  const isMac = process.platform === 'darwin';
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      {
        label: 'File',
        submenu: [isMac ? { role: 'close' } : { role: 'quit' }],
      },
      {
        label: 'Edit',
        submenu: [
          { role: 'undo' },
          { role: 'redo' },
          { type: 'separator' },
          { role: 'cut' },
          { role: 'copy' },
          { role: 'paste' },
          { role: 'selectAll' },
        ],
      },
      {
        label: 'View',
        submenu: [
          { role: 'reload' },
          { role: 'forceReload' },
          { role: 'toggleDevTools' },
          { type: 'separator' },
          { role: 'resetZoom' },
          { role: 'zoomIn' },
          { role: 'zoomOut' },
          { type: 'separator' },
          { role: 'togglefullscreen' },
        ],
      },
    ])
  );
}

// VS Code's integrated terminal exports ELECTRON_RUN_AS_NODE=1, which makes the
// electron binary behave as plain Node and leaves the electron module empty.
if (!app || typeof app.whenReady !== 'function') {
  console.error(
    'Electron APIs are unavailable. ELECTRON_RUN_AS_NODE is probably set in ' +
      'this shell (VS Code sets it). Unset it and run `npm run dev` again.'
  );
  process.exit(1);
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const [win] = BrowserWindow.getAllWindows();
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });

  app.whenReady().then(async () => {
    // Nothing in the editor needs camera, mic, geolocation or notifications.
    session.defaultSession.setPermissionRequestHandler((_wc, _perm, done) =>
      done(false)
    );

    await startServer();
    buildMenu();
    createWindow();

    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
  });

  app.on('window-all-closed', () => {
    if (httpServer) httpServer.close();
    if (process.platform !== 'darwin') app.quit();
  });
}
