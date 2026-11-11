/** @OnlyCurrentDoc */
/**
 * Doomscroll Rehab 官網的等候名單：網頁表單送來的資料，寫進這份 Google 試算表的「名單」分頁。
 * 只會「新增一列」，不會讀、改、刪任何資料。
 *
 * - 第一行的 @OnlyCurrentDoc：只要求「這一份試算表」的權限，不是你所有的試算表。
 * - 文字欄位一律前面加 '：= + - @ 開頭的內容不會被當成公式執行。
 * - 同一個 email 6 小時內只記一次（重按不會變好幾列）。
 * - 全站每 10 分鐘最多記 60 筆，超過就請對方晚點再試（被人用程式洗版時，名單不會被灌爆）。
 * - 等不到鎖時回「忙碌」，不會丟出 Google 的錯誤頁。
 */
var SHEET_NAME = '名單';
var APPS = ['YouTube', 'Instagram', 'TikTok', 'Threads', 'Facebook', 'X', 'Reddit', '小紅書', 'Dcard'];
var MAX_PER_10_MIN = 60;
var SAME_EMAIL_SECONDS = 6 * 60 * 60;   // CacheService 最長只能存 6 小時

function doPost(e) {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(10000)) return reply({ ok: false, error: 'busy' });
  try {
    var p = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var email = clip(p.email, 254).toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email)) return reply({ ok: false, error: 'bad' });

    var cache = CacheService.getScriptCache();
    var who = 'e:' + Utilities.base64EncodeWebSafe(Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, email, Utilities.Charset.UTF_8));
    if (cache.get(who)) return reply({ ok: true });   // 剛剛已經登記過：不再多記一列。回應和新登記完全一樣，不讓人拿別人的 email 來試探
    var win = 'w:' + Math.floor(Date.now() / 600000), count = Number(cache.get(win) || 0);
    if (count >= MAX_PER_10_MIN) return reply({ ok: false, error: 'busy' });

    // 只收清單裡的 App 名稱，其他一律丟掉
    var picked = [];
    if (p.apps && p.apps.length) {
      for (var i = 0; i < p.apps.length && i < 20; i++) if (APPS.indexOf(String(p.apps[i])) !== -1) picked.push(String(p.apps[i]));
    }

    var book = SpreadsheetApp.getActiveSpreadsheet();
    var sh = book.getSheetByName(SHEET_NAME) || book.insertSheet(SHEET_NAME);
    if (sh.getLastRow() === 0) {
      sh.appendRow(['時間', 'email', '想少滑的 App', '語言', '從哪個網頁來']);
      sh.setFrozenRows(1);
    }
    sh.appendRow([
      new Date(),
      text(email),
      text(picked.join('、')),
      p.lang === 'zh' ? '中文' : 'English',
      text(clip(p.referrer, 300))
    ]);
    cache.put(who, '1', SAME_EMAIL_SECONDS);
    cache.put(win, String(count + 1), 900);
    return reply({ ok: true });
  } catch (err) {
    return reply({ ok: false, error: 'server' });
  } finally {
    lock.releaseLock();
  }
}

// 用網址直接打開時，顯示一行字確認部署成功
function doGet() {
  return ContentService.createTextOutput('Doomscroll Rehab 等候名單：部署成功。');
}

function clip(v, n) { return String(v == null ? '' : v).trim().slice(0, n); }

// 一律當成文字存：開頭加 '（試算表上看不到這個符號）。空字串就留空
function text(s) { return s ? "'" + s : ''; }

function reply(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
