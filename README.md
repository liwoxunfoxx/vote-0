# 雲端投票站

這是直接以瀏覽器執行的投票網站。`index.html` 提供建立及參與投票，`admin.html` 提供登入後的投票管理。

## 部署這次變更

前端使用既有的 Supabase 專案。先在該專案執行 `supabase/migrations/20261019000000_vote_limit_and_edit.sql`，再部署兩個 HTML 檔。SQL 會新增 `cast_vote_limited` 與 `admin_update_poll`，並撤銷公開角色呼叫舊 `cast_vote` 及直接更新 `polls` 的權限，避免繞過每次投票上限。若資料庫未套用遷移，新的投票按鈕與編輯功能會收到找不到 RPC 的錯誤。

遷移預期現有資料庫包含 `public.polls`（`id text`、`data jsonb`、`created_at`）與 `is_poll_admin()`，而原有 `create_poll`、`admin_list_polls`、`admin_delete_poll` 繼續由現有專案提供。這些既有結構沒有包含在此儲存庫內。

## 功能規則

- 多選投票可設定每張選票最多選幾項；單選固定為 1 項。舊投票沒有上限欄位時，多選沿用「最多選全部選項」的行為。
- 管理者可編輯投票內容與選項。已有票數的選項不能刪除；已有票數的投票不能改變單選／多選或匿名設定。編輯時既有票數、投票者清單與已投票識別碼都會保留。
- 管理者身分由現有 `is_poll_admin()` 函式決定。前端的投票者識別碼存在瀏覽器的 localStorage，不能視為強身分驗證。
