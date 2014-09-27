ISUCON4
=======

アプリの挙動メモ

# 改善候補

## sessionストア

```
store => Plack::Session::Store::File->new(
  dir         => $session_dir,
),
```

# アプリのパス

/
/login
/mypage
/report

のみ

* /mypage では、login_logから取得した最終ログイン日時と、最終ログインIPが分かれば良い
* /login では、login_logにログインの履歴を残す(パスワードを間違えた場合も記録)
 * 一定回数間違えるとアカウントロックされてログインできない
 * 同一IPからのログインが一定回数を超えるとban IPに登録されて同IPからはログインできない
* /report では、↑のロックされたユーザーの一覧とbanされたIPの一覧をJSONで返す

# ベンチマークの挙動

* dummyのusersとlogin_logの登録を行なっている → login_log構造をいじるなら、init.shの直後に処理しないと不味い

## ベンチマークでアクセスされるpathランキング

```
1632 path:/stylesheets/isucon-bank.css
1632 path:/stylesheets/bootstrap.min.css
1632 path:/stylesheets/bootflat.min.css
1632 path:/images/isucon-bank.png
1494 path:/
 816 path:/login
 138 path:/mypage
   1 path:/report
```
