ISUCON4
=======

アプリの挙動メモ

# アプリのパス

/
/login
/mypage
/report

のみ

* /mypage では、login_logから取得した最終ログイン日時と、最終ログインIPが分かれば良い
* /login では、login_logにログインの履歴を残す(パスワードを間違えた場合も記録)
** 一定回数間違えるとアカウントロックされてログインできない
** 同一IPからのログインが一定回数を超えるとban IPに登録されて同IPからはログインできない
* /report では、↑のロックされたユーザーの一覧とbanされたIPの一覧をJSONで返す

# ベンチマークの挙動

* dummyのusersとlogin_logの登録を行なっている → login_log構造をいじるなら、init.shの直後に処理しないと不味い
