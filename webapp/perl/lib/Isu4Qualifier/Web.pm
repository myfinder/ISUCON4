package Isu4Qualifier::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use Digest::SHA qw/ sha256_hex /;
use Data::Dumper;

sub config {
  my ($self) = @_;
  $self->{_config} ||= {
    user_lock_threshold => $ENV{'ISU4_USER_LOCK_THRESHOLD'} || 3,
    ip_ban_threshold => $ENV{'ISU4_IP_BAN_THRESHOLD'} || 10
  };
};

sub db {
  my ($self) = @_;
  my $host = $ENV{ISU4_DB_HOST} || '127.0.0.1';
  my $port = $ENV{ISU4_DB_PORT} || 3306;
  my $username = $ENV{ISU4_DB_USER} || 'root';
  my $password = $ENV{ISU4_DB_PASSWORD};
  my $database = $ENV{ISU4_DB_NAME} || 'isu4_qualifier';

  $self->{_db} ||= do {
    DBIx::Sunny->connect(
      "dbi:mysql:database=$database;host=$host;port=$port", $username, $password, {
        RaiseError => 1,
        PrintError => 0,
        AutoInactiveDestroy => 1,
        mysql_enable_utf8   => 1,
        mysql_auto_reconnect => 1,
      },
    );
  };
}

sub calculate_password_hash {
  my ($password, $salt) = @_;
  sha256_hex($password . ':' . $salt);
};

sub attempt_login {
  my ($self, $login, $password, $ip) = @_;
  my $user = $self->db->select_row('SELECT * FROM users WHERE login = ?', $login);
  my $fail_ip = $self->db->select_row('SELECT * FROM fail_ips WHERE ip = ?', $ip);

  if ($fail_ip && $self->config->{ip_ban_threshold} <= $fail_ip->{fail_count}) {
    $self->login_log(0, $login, $ip, $user ? $user->{id} : undef);
    return undef, 'banned';
  }

  if ($self->config->{user_lock_threshold} <= $user->{fail_count}) {
    $self->login_log(0, $login, $ip, $user->{id});
    return undef, 'locked';
  }

  if ($user && calculate_password_hash($password, $user->{salt}) eq $user->{password_hash}) {
    $self->login_log(1, $login, $ip, $user->{id});
    return $user, undef;
  }
  elsif ($user) {
    $self->login_log(0, $login, $ip, $user->{id});
    return undef, 'wrong_password';
  }
  else {
    $self->login_log(0, $login, $ip);
    return undef, 'wrong_login';
  }
};

sub current_user {
  my ($self, $user_id) = @_;

  $self->db->select_row('SELECT * FROM users WHERE id = ?', $user_id);
};

sub banned_ips {
  my ($self) = @_;
  my @ips;
  my $threshold = $self->config->{ip_ban_threshold};
  my $rows = $self->db->select_all(q{SELECT ip FROM fail_ips WHERE fail_count >= ?}, $threshold);

  return [map { $_->{ip} } @$rows];
};

sub locked_users {
  my ($self) = @_;
  my $threshold = $self->config->{user_lock_threshold};
  my $rows = $self->db->select_all(q{SELECT login FROM users WHERE fail_count >= ?}, $threshold);

  return [map { $_->{login} } @$rows];
};

sub login_log {
  my ($self, $succeeded, $login, $ip, $user_id) = @_;
  $self->db->query(
    'INSERT INTO login_log (`created_at`, `user_id`, `login`, `ip`, `succeeded`) VALUES (NOW(),?,?,?,?)',
    $user_id, $login, $ip, ($succeeded ? 1 : 0)
  );
  if ($succeeded) {
    $self->db->query(q{UPDATE users SET fail_count = 0, last_login_at = NOW(), last_login_ip = ? WHERE id = ?}, 
                     $ip, $user_id);
    $self->db->query(q{DELETE FROM fail_ips WHERE ip = ?}, $ip);
  } else {
    $self->db->query(q{UPDATE users SET fail_count = fail_count + 1 WHERE id = ?}, $user_id);
    if ($self->db->select_row(q{SELECT * FROM fail_ips WHERE ip = ?}, $ip)) {
      $self->db->query(q{UPDATE fail_ips SET fail_count = fail_count + 1 WHERE ip = ?}, $ip);
    } else {
      $self->db->query(q{INSERT INTO fail_ips(ip, fail_count) VALUES(?, 1)}, $ip);
    }
  }
};

sub set_flash {
  my ($self, $c, $msg) = @_;
  $c->req->env->{'psgix.session'}->{flash} = $msg;
};

sub pop_flash {
  my ($self, $c, $msg) = @_;
  my $flash = $c->req->env->{'psgix.session'}->{flash};
  delete $c->req->env->{'psgix.session'}->{flash};
  $flash;
};

filter 'session' => sub {
  my ($app) = @_;
  sub {
    my ($self, $c) = @_;
    my $sid = $c->req->env->{'psgix.session.options'}->{id};
    $c->stash->{session_id} = $sid;
    $c->stash->{session}    = $c->req->env->{'psgix.session'};
    $app->($self, $c);
  };
};

get '/' => [qw(session)] => sub {
  my ($self, $c) = @_;

  $c->render('index.tx', { flash => $self->pop_flash($c) });
};

post '/login' => sub {
  my ($self, $c) = @_;
  my $msg;

  my ($user, $err) = $self->attempt_login(
    $c->req->param('login'),
    $c->req->param('password'),
    $c->req->address
  );

  if ($user && $user->{id}) {
    $c->req->env->{'psgix.session'}->{user_id} = $user->{id};
    $c->req->env->{'psgix.session'}->{last_login_at} = $user->{last_login_at};
    $c->req->env->{'psgix.session'}->{last_login_ip} = $user->{last_login_ip};
    $c->redirect('/mypage');
  }
  else {
    if ($err eq 'locked') {
      $self->set_flash($c, 'This account is locked.');
    }
    elsif ($err eq 'banned') {
      $self->set_flash($c, "You're banned.");
    }
    else {
      $self->set_flash($c, 'Wrong username or password');
    }
    $c->redirect('/');
  }
};

get '/mypage' => [qw(session)] => sub {
  my ($self, $c) = @_;
  my $user_id = $c->req->env->{'psgix.session'}->{user_id};
  my $user = $self->current_user($user_id);
  my $msg;

  if ($user) {
    $c->render('mypage.tx', { 
      user_login    => $user->{login},
      last_login_at => $c->req->env->{'psgix.session'}->{last_login_at},
      last_login_ip => $c->req->env->{'psgix.session'}->{last_login_ip},
    });
  }
  else {
    $self->set_flash($c, "You must be logged in");
    $c->redirect('/');
  }
};

get '/report' => sub {
  my ($self, $c) = @_;
  $c->render_json({
    banned_ips => $self->banned_ips,
    locked_users => $self->locked_users,
  });
};

1;
