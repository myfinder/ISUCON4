use 5.008001;
use strict;
use warnings;

package Path::Tiny;
# ABSTRACT: File path utility
our $VERSION = '0.057'; # VERSION

# Dependencies
use Config;
use Exporter 5.57   (qw/import/);
use File::Spec 3.40 ();
use Carp ();

our @EXPORT    = qw/path/;
our @EXPORT_OK = qw/cwd rootdir tempfile tempdir/;

use constant {
    PATH     => 0,
    CANON    => 1,
    VOL      => 2,
    DIR      => 3,
    FILE     => 4,
    TEMP     => 5,
    IS_BSD   => ( scalar $^O =~ /bsd$/ ),
    IS_WIN32 => ( $^O eq 'MSWin32' ),
};

use overload (
    q{""}    => sub    { $_[0]->[PATH] },
    bool     => sub () { 1 },
    fallback => 1,
);

# FREEZE/THAW per Sereal/CBOR/Types::Serialiser protocol
sub FREEZE { return $_[0]->[PATH] }
sub THAW   { return path( $_[2] ) }
{ no warnings 'once'; *TO_JSON = *FREEZE };

my $HAS_UU; # has Unicode::UTF8; lazily populated

sub _check_UU {
    eval { require Unicode::UTF8; Unicode::UTF8->VERSION(0.58); 1 };
}

my $HAS_FLOCK = $Config{d_flock} || $Config{d_fcntl_can_lock} || $Config{d_lockf};

# notions of "root" directories differ on Win32: \\server\dir\ or C:\ or \
my $SLASH      = qr{[\\/]};
my $NOTSLASH   = qr{[^\\/]};
my $DRV_VOL    = qr{[a-z]:}i;
my $UNC_VOL    = qr{$SLASH $SLASH $NOTSLASH+ $SLASH $NOTSLASH+}x;
my $WIN32_ROOT = qr{(?: $UNC_VOL $SLASH | $DRV_VOL $SLASH | $SLASH )}x;

sub _win32_vol {
    my ( $path, $drv ) = @_;
    require Cwd;
    my $dcwd = eval { Cwd::getdcwd($drv) }; # C: -> C:\some\cwd
    # getdcwd on non-existent drive returns empty string
    # so just use the original drive Z: -> Z:
    $dcwd = "$drv" unless defined $dcwd && length $dcwd;
    # normalize dwcd to end with a slash: might be C:\some\cwd or D:\ or Z:
    $dcwd =~ s{$SLASH?$}{/};
    # make the path absolute with dcwd
    $path =~ s{^$DRV_VOL}{$dcwd};
    return $path;
}

# This is a string test for before we have the object; see is_rootdir for well-formed
# object test
sub _is_root {
    return IS_WIN32() ? ( $_[0] =~ /^$WIN32_ROOT$/ ) : ( $_[0] eq '/' );
}

# mode bits encoded for chmod in symbolic mode
my %MODEBITS = ( om => 0007, gm => 0070, um => 0700 ); ## no critic
{ my $m = 0; $MODEBITS{$_} = ( 1 << $m++ ) for qw/ox ow or gx gw gr ux uw ur/ };

sub _symbolic_chmod {
    my ( $mode, $symbolic ) = @_;
    for my $clause ( split /,\s*/, $symbolic ) {
        if ( $clause =~ m{\A([augo]+)([=+-])([rwx]+)\z} ) {
            my ( $who, $action, $perms ) = ( $1, $2, $3 );
            $who =~ s/a/ugo/g;
            for my $w ( split //, $who ) {
                my $p = 0;
                $p |= $MODEBITS{"$w$_"} for split //, $perms;
                if ( $action eq '=' ) {
                    $mode = ( $mode & ~$MODEBITS{"${w}m"} ) | $p;
                }
                else {
                    $mode = $action eq "+" ? ( $mode | $p ) : ( $mode & ~$p );
                }
            }
        }
        else {
            Carp::croak("Invalid mode clause '$clause' for chmod()");
        }
    }
    return $mode;
}

# flock doesn't work on NFS on BSD.  Since program authors often can't control
# or detect that, we warn once instead of being fatal if we can detect it and
# people who need it strict can fatalize the 'flock' category

#<<< No perltidy
{ package flock; use if Path::Tiny::IS_BSD(), 'warnings::register' }
#>>>

my $WARNED_BSD_NFS = 0;

sub _throw {
    my ( $self, $function, $file ) = @_;
    if (   IS_BSD()
        && $function =~ /^flock/
        && $! =~ /operation not supported/i
        && !warnings::fatal_enabled('flock') )
    {
        if ( !$WARNED_BSD_NFS ) {
            warnings::warn( flock => "No flock for NFS on BSD: continuing in unsafe mode" );
            $WARNED_BSD_NFS++;
        }
    }
    else {
        Path::Tiny::Error->throw( $function, ( defined $file ? $file : $self->[PATH] ), $! );
    }
    return;
}

# cheapo option validation
sub _get_args {
    my ( $raw, @valid ) = @_;
    if ( defined($raw) && ref($raw) ne 'HASH' ) {
        my ( undef, undef, undef, $called_as ) = caller(1);
        $called_as =~ s{^.*::}{};
        Carp::croak("Options for $called_as must be a hash reference");
    }
    my $cooked = {};
    for my $k (@valid) {
        $cooked->{$k} = delete $raw->{$k} if exists $raw->{$k};
    }
    if ( keys %$raw ) {
        my ( undef, undef, undef, $called_as ) = caller(1);
        $called_as =~ s{^.*::}{};
        Carp::croak( "Invalid option(s) for $called_as: " . join( ", ", keys %$raw ) );
    }
    return $cooked;
}

#--------------------------------------------------------------------------#
# Constructors
#--------------------------------------------------------------------------#

#pod =construct path
#pod
#pod     $path = path("foo/bar");
#pod     $path = path("/tmp", "file.txt"); # list
#pod     $path = path(".");                # cwd
#pod     $path = path("~user/file.txt");   # tilde processing
#pod
#pod Constructs a C<Path::Tiny> object.  It doesn't matter if you give a file or
#pod directory path.  It's still up to you to call directory-like methods only on
#pod directories and file-like methods only on files.  This function is exported
#pod automatically by default.
#pod
#pod The first argument must be defined and have non-zero length or an exception
#pod will be thrown.  This prevents subtle, dangerous errors with code like
#pod C<< path( maybe_undef() )->remove_tree >>.
#pod
#pod If the first component of the path is a tilde ('~') then the component will be
#pod replaced with the output of C<glob('~')>.  If the first component of the path
#pod is a tilde followed by a user name then the component will be replaced with
#pod output of C<glob('~username')>.  Behaviour for non-existent users depends on
#pod the output of C<glob> on the system.
#pod
#pod On Windows, if the path consists of a drive identifier without a path component
#pod (C<C:> or C<D:>), it will be expanded to the absolute path of the current
#pod directory on that volume using C<Cwd::getdcwd()>.
#pod
#pod If called with a single C<Path::Tiny> argument, the original is returned unless
#pod the original is holding a temporary file or directory reference in which case a
#pod stringified copy is made.
#pod
#pod     $path = path("foo/bar");
#pod     $temp = Path::Tiny->tempfile;
#pod
#pod     $p2 = path($path); # like $p2 = $path
#pod     $t2 = path($temp); # like $t2 = path( "$temp" )
#pod
#pod This optimizes copies without proliferating references unexpectedly if a copy is
#pod made by code outside your control.
#pod
#pod =cut

sub path {
    my $path = shift;
    Carp::croak("Path::Tiny paths require defined, positive-length parts")
      unless 1 + @_ == grep { defined && length } $path, @_;

    # non-temp Path::Tiny objects are effectively immutable and can be reused
    if ( !@_ && ref($path) eq __PACKAGE__ && !$path->[TEMP] ) {
        return $path;
    }

    # stringify objects
    $path = "$path";

    # expand relative volume paths on windows; put trailing slash on UNC root
    if ( IS_WIN32() ) {
        $path = _win32_vol( $path, $1 ) if $path =~ m{^($DRV_VOL)(?:$NOTSLASH|$)};
        $path .= "/" if $path =~ m{^$UNC_VOL$};
    }

    # concatenations stringifies objects, too
    if (@_) {
        $path .= ( _is_root($path) ? "" : "/" ) . join( "/", @_ );
    }

    # canonicalize, but with unix slashes and put back trailing volume slash
    my $cpath = $path = File::Spec->canonpath($path);
    $path =~ tr[\\][/] if IS_WIN32();
    $path .= "/" if IS_WIN32() && $path =~ m{^$UNC_VOL$};

    # root paths must always have a trailing slash, but other paths must not
    if ( _is_root($path) ) {
        $path =~ s{/?$}{/};
    }
    else {
        $path =~ s{/$}{};
    }

    # do any tilde expansions
    if ( $path =~ m{^(~[^/]*).*} ) {
        my ($homedir) = glob($1); # glob without list context == heisenbug!
        $path =~ s{^(~[^/]*)}{$homedir};
    }

    bless [ $path, $cpath ], __PACKAGE__;
}

#pod =construct new
#pod
#pod     $path = Path::Tiny->new("foo/bar");
#pod
#pod This is just like C<path>, but with method call overhead.  (Why would you
#pod do that?)
#pod
#pod =cut

sub new { shift; path(@_) }

#pod =construct cwd
#pod
#pod     $path = Path::Tiny->cwd; # path( Cwd::getcwd )
#pod     $path = cwd; # optional export
#pod
#pod Gives you the absolute path to the current directory as a C<Path::Tiny> object.
#pod This is slightly faster than C<< path(".")->absolute >>.
#pod
#pod C<cwd> may be exported on request and used as a function instead of as a
#pod method.
#pod
#pod =cut

sub cwd {
    require Cwd;
    return path( Cwd::getcwd() );
}

#pod =construct rootdir
#pod
#pod     $path = Path::Tiny->rootdir; # /
#pod     $path = rootdir;             # optional export 
#pod
#pod Gives you C<< File::Spec->rootdir >> as a C<Path::Tiny> object if you're too
#pod picky for C<path("/")>.
#pod
#pod C<rootdir> may be exported on request and used as a function instead of as a
#pod method.
#pod
#pod =cut

sub rootdir { path( File::Spec->rootdir ) }

#pod =construct tempfile, tempdir
#pod
#pod     $temp = Path::Tiny->tempfile( @options );
#pod     $temp = Path::Tiny->tempdir( @options );
#pod     $temp = tempfile( @options ); # optional export
#pod     $temp = tempdir( @options );  # optional export
#pod
#pod C<tempfile> passes the options to C<< File::Temp->new >> and returns a C<Path::Tiny>
#pod object with the file name.  The C<TMPDIR> option is enabled by default.
#pod
#pod The resulting C<File::Temp> object is cached. When the C<Path::Tiny> object is
#pod destroyed, the C<File::Temp> object will be as well.
#pod
#pod C<File::Temp> annoyingly requires you to specify a custom template in slightly
#pod different ways depending on which function or method you call, but
#pod C<Path::Tiny> lets you ignore that and can take either a leading template or a
#pod C<TEMPLATE> option and does the right thing.
#pod
#pod     $temp = Path::Tiny->tempfile( "customXXXXXXXX" );             # ok
#pod     $temp = Path::Tiny->tempfile( TEMPLATE => "customXXXXXXXX" ); # ok
#pod
#pod The tempfile path object will normalized to have an absolute path, even if
#pod created in a relative directory using C<DIR>.
#pod
#pod C<tempdir> is just like C<tempfile>, except it calls
#pod C<< File::Temp->newdir >> instead.
#pod
#pod Both C<tempfile> and C<tempdir> may be exported on request and used as
#pod functions instead of as methods.
#pod
#pod =cut

sub tempfile {
    shift if @_ && $_[0] eq 'Path::Tiny'; # called as method
    my ( $maybe_template, $args ) = _parse_file_temp_args(@_);
    # File::Temp->new demands TEMPLATE
    $args->{TEMPLATE} = $maybe_template->[0] if @$maybe_template;

    require File::Temp;
    my $temp = File::Temp->new( TMPDIR => 1, %$args );
    close $temp;
    my $self = path($temp)->absolute;
    $self->[TEMP] = $temp;                # keep object alive while we are
    return $self;
}

sub tempdir {
    shift if @_ && $_[0] eq 'Path::Tiny'; # called as method
    my ( $maybe_template, $args ) = _parse_file_temp_args(@_);

    # File::Temp->newdir demands leading template
    require File::Temp;
    my $temp = File::Temp->newdir( @$maybe_template, TMPDIR => 1, %$args );
    my $self = path($temp)->absolute;
    $self->[TEMP] = $temp;                # keep object alive while we are
    return $self;
}

# normalize the various ways File::Temp does templates
sub _parse_file_temp_args {
    my $leading_template = ( scalar(@_) % 2 == 1 ? shift(@_) : '' );
    my %args = @_;
    %args = map { uc($_), $args{$_} } keys %args;
    my @template = (
          exists $args{TEMPLATE} ? delete $args{TEMPLATE}
        : $leading_template      ? $leading_template
        :                          ()
    );
    return ( \@template, \%args );
}

#--------------------------------------------------------------------------#
# Private methods
#--------------------------------------------------------------------------#

sub _splitpath {
    my ($self) = @_;
    @{$self}[ VOL, DIR, FILE ] = File::Spec->splitpath( $self->[PATH] );
}

#--------------------------------------------------------------------------#
# Public methods
#--------------------------------------------------------------------------#

#pod =method absolute
#pod
#pod     $abs = path("foo/bar")->absolute;
#pod     $abs = path("foo/bar")->absolute("/tmp");
#pod
#pod Returns a new C<Path::Tiny> object with an absolute path (or itself if already
#pod absolute).  Unless an argument is given, the current directory is used as the
#pod absolute base path.  The argument must be absolute or you won't get an absolute
#pod result.
#pod
#pod This will not resolve upward directories ("foo/../bar") unless C<canonpath>
#pod in L<File::Spec> would normally do so on your platform.  If you need them
#pod resolved, you must call the more expensive C<realpath> method instead.
#pod
#pod On Windows, an absolute path without a volume component will have it added
#pod based on the current drive.
#pod
#pod =cut

sub absolute {
    my ( $self, $base ) = @_;

    # absolute paths handled differently by OS
    if (IS_WIN32) {
        return $self if length $self->volume;
        # add missing volume
        if ( $self->is_absolute ) {
            require Cwd;
            # use Win32::GetCwd not Cwd::getdcwd because we're sure
            # to have the former but not necessarily the latter
            my ($drv) = Win32::GetCwd() =~ /^($DRV_VOL | $UNC_VOL)/x;
            return path( $drv . $self->[PATH] );
        }
    }
    else {
        return $self if $self->is_absolute;
    }

    # relative path on any OS
    require Cwd;
    return path( ( defined($base) ? $base : Cwd::getcwd() ), $_[0]->[PATH] );
}

#pod =method append, append_raw, append_utf8
#pod
#pod     path("foo.txt")->append(@data);
#pod     path("foo.txt")->append(\@data);
#pod     path("foo.txt")->append({binmode => ":raw"}, @data);
#pod     path("foo.txt")->append_raw(@data);
#pod     path("foo.txt")->append_utf8(@data);
#pod
#pod Appends data to a file.  The file is locked with C<flock> prior to writing.  An
#pod optional hash reference may be used to pass options.  The only option is
#pod C<binmode>, which is passed to C<binmode()> on the handle used for writing.
#pod
#pod C<append_raw> is like C<append> with a C<binmode> of C<:unix> for fast,
#pod unbuffered, raw write.
#pod
#pod C<append_utf8> is like C<append> with a C<binmode> of
#pod C<:unix:encoding(UTF-8)>.  If L<Unicode::UTF8> 0.58+ is installed, a raw
#pod append will be done instead on the data encoded with C<Unicode::UTF8>.
#pod
#pod =cut

sub append {
    my ( $self, @data ) = @_;
    my $args = ( @data && ref $data[0] eq 'HASH' ) ? shift @data : {};
    $args = _get_args( $args, qw/binmode/ );
    my $binmode = $args->{binmode};
    $binmode = ( ( caller(0) )[10] || {} )->{'open>'} unless defined $binmode;
    my $fh = $self->filehandle( { locked => 1 }, ">>", $binmode );
    print {$fh} map { ref eq 'ARRAY' ? @$_ : $_ } @data;
    close $fh or $self->_throw('close');
}

sub append_raw { splice @_, 1, 0, { binmode => ":unix" }; goto &append }

sub append_utf8 {
    if ( defined($HAS_UU) ? $HAS_UU : $HAS_UU = _check_UU() ) {
        my $self = shift;
        append( $self, { binmode => ":unix" }, map { Unicode::UTF8::encode_utf8($_) } @_ );
    }
    else {
        splice @_, 1, 0, { binmode => ":unix:encoding(UTF-8)" };
        goto &append;
    }
}

#pod =method basename
#pod
#pod     $name = path("foo/bar.txt")->basename;        # bar.txt
#pod     $name = path("foo.txt")->basename('.txt');    # foo
#pod     $name = path("foo.txt")->basename(qr/.txt/);  # foo
#pod     $name = path("foo.txt")->basename(@suffixes);
#pod
#pod Returns the file portion or last directory portion of a path.
#pod
#pod Given a list of suffixes as strings or regular expressions, any that match at
#pod the end of the file portion or last directory portion will be removed before
#pod the result is returned.
#pod
#pod =cut

sub basename {
    my ( $self, @suffixes ) = @_;
    $self->_splitpath unless defined $self->[FILE];
    my $file = $self->[FILE];
    for my $s (@suffixes) {
        my $re = ref($s) eq 'Regexp' ? qr/$s$/ : qr/\Q$s\E$/;
        last if $file =~ s/$re//;
    }
    return $file;
}

#pod =method canonpath
#pod
#pod     $canonical = path("foo/bar")->canonpath; # foo\bar on Windows
#pod
#pod Returns a string with the canonical format of the path name for
#pod the platform.  In particular, this means directory separators
#pod will be C<\> on Windows.
#pod
#pod =cut

sub canonpath { $_[0]->[CANON] }

#pod =method child
#pod
#pod     $file = path("/tmp")->child("foo.txt"); # "/tmp/foo.txt"
#pod     $file = path("/tmp")->child(@parts);
#pod
#pod Returns a new C<Path::Tiny> object relative to the original.  Works
#pod like C<catfile> or C<catdir> from File::Spec, but without caring about
#pod file or directories.
#pod
#pod =cut

sub child {
    my ( $self, @parts ) = @_;
    return path( $self->[PATH], @parts );
}

#pod =method children
#pod
#pod     @paths = path("/tmp")->children;
#pod     @paths = path("/tmp")->children( qr/\.txt$/ );
#pod
#pod Returns a list of C<Path::Tiny> objects for all files and directories
#pod within a directory.  Excludes "." and ".." automatically.
#pod
#pod If an optional C<qr//> argument is provided, it only returns objects for child
#pod names that match the given regular expression.  Only the base name is used
#pod for matching:
#pod
#pod     @paths = path("/tmp")->children( qr/^foo/ );
#pod     # matches children like the glob foo*
#pod
#pod =cut

sub children {
    my ( $self, $filter ) = @_;
    my $dh;
    opendir $dh, $self->[PATH] or $self->_throw('opendir');
    my @children = readdir $dh;
    closedir $dh or $self->_throw('closedir');

    if ( not defined $filter ) {
        @children = grep { $_ ne '.' && $_ ne '..' } @children;
    }
    elsif ( $filter && ref($filter) eq 'Regexp' ) {
        @children = grep { $_ ne '.' && $_ ne '..' && $_ =~ $filter } @children;
    }
    else {
        Carp::croak("Invalid argument '$filter' for children()");
    }

    return map { path( $self->[PATH], $_ ) } @children;
}

#pod =method chmod
#pod
#pod     path("foo.txt")->chmod(0777);
#pod     path("foo.txt")->chmod("0755");
#pod     path("foo.txt")->chmod("go-w");
#pod     path("foo.txt")->chmod("a=r,u+wx");
#pod
#pod Sets file or directory permissions.  The argument can be a numeric mode, a
#pod octal string beginning with a "0" or a limited subset of the symbolic mode use
#pod by F</bin/chmod>.
#pod
#pod The symbolic mode must be a comma-delimited list of mode clauses.  Clauses must
#pod match C<< qr/\A([augo]+)([=+-])([rwx]+)\z/ >>, which defines "who", "op" and
#pod "perms" parameters for each clause.  Unlike F</bin/chmod>, all three parameters
#pod are required for each clause, multiple ops are not allowed and permissions
#pod C<stugoX> are not supported.  (See L<File::chmod> for more complex needs.)
#pod
#pod =cut

sub chmod {
    my ( $self, $new_mode ) = @_;

    my $mode;
    if ( $new_mode =~ /\d/ ) {
        $mode = ( $new_mode =~ /^0/ ? oct($new_mode) : $new_mode );
    }
    elsif ( $new_mode =~ /[=+-]/ ) {
        $mode = _symbolic_chmod( $self->stat->mode & 07777, $new_mode ); ## no critic
    }
    else {
        Carp::croak("Invalid mode argument '$new_mode' for chmod()");
    }

    CORE::chmod( $mode, $self->[PATH] ) or $self->_throw("chmod");

    return 1;
}

#pod =method copy
#pod
#pod     path("/tmp/foo.txt")->copy("/tmp/bar.txt");
#pod
#pod Copies a file using L<File::Copy>'s C<copy> function.
#pod
#pod =cut

# XXX do recursively for directories?
sub copy {
    my ( $self, $dest ) = @_;
    require File::Copy;
    File::Copy::copy( $self->[PATH], $dest )
      or Carp::croak("copy failed for $self to $dest: $!");
}

#pod =method digest
#pod
#pod     $obj = path("/tmp/foo.txt")->digest;        # SHA-256
#pod     $obj = path("/tmp/foo.txt")->digest("MD5"); # user-selected
#pod     $obj = path("/tmp/foo.txt")->digest( { chunk_size => 1e6 }, "MD5" );
#pod
#pod Returns a hexadecimal digest for a file.  An optional hash reference of options may
#pod be given.  The only option is C<chunk_size>.  If C<chunk_size> is given, that many
#pod bytes will be read at a time.  If not provided, the entire file will be slurped
#pod into memory to compute the digest.
#pod
#pod Any subsequent arguments are passed to the constructor for L<Digest> to select
#pod an algorithm.  If no arguments are given, the default is SHA-256.
#pod
#pod =cut

sub digest {
    my ( $self, @opts ) = @_;
    my $args = ( @opts && ref $opts[0] eq 'HASH' ) ? shift @opts : {};
    $args = _get_args( $args, qw/chunk_size/ );
    unshift @opts, 'SHA-256' unless @opts;
    require Digest;
    my $digest = Digest->new(@opts);
    if ( $args->{chunk_size} ) {
        my $fh = $self->filehandle( { locked => 1 }, "<", ":unix" );
        my $buf;
        $digest->add($buf) while read $fh, $buf, $args->{chunk_size};
    }
    else {
        $digest->add( $self->slurp_raw );
    }
    return $digest->hexdigest;
}

#pod =method dirname (deprecated)
#pod
#pod     $name = path("/tmp/foo.txt")->dirname; # "/tmp/"
#pod
#pod Returns the directory portion you would get from calling
#pod C<< File::Spec->splitpath( $path->stringify ) >> or C<"."> for a path without a
#pod parent directory portion.  Because L<File::Spec> is inconsistent, the result
#pod might or might not have a trailing slash.  Because of this, this method is
#pod B<deprecated>.
#pod
#pod A better, more consistently approach is likely C<< $path->parent->stringify >>,
#pod which will not have a trailing slash except for a root directory.
#pod
#pod =cut

sub dirname {
    my ($self) = @_;
    $self->_splitpath unless defined $self->[DIR];
    return length $self->[DIR] ? $self->[DIR] : ".";
}

#pod =method exists, is_file, is_dir
#pod
#pod     if ( path("/tmp")->exists ) { ... }     # -e
#pod     if ( path("/tmp")->is_dir ) { ... }     # -d
#pod     if ( path("/tmp")->is_file ) { ... }    # -e && ! -d
#pod
#pod Implements file test operations, this means the file or directory actually has
#pod to exist on the filesystem.  Until then, it's just a path.
#pod
#pod B<Note>: C<is_file> is not C<-f> because C<-f> is not the opposite of C<-d>.
#pod C<-f> means "plain file", excluding symlinks, devices, etc. that often can be
#pod read just like files.
#pod
#pod Use C<-f> instead if you really mean to check for a plain file.
#pod
#pod
#pod =cut

sub exists { -e $_[0]->[PATH] }

sub is_file { -e $_[0]->[PATH] && !-d _ }

sub is_dir { -d $_[0]->[PATH] }

#pod =method filehandle
#pod
#pod     $fh = path("/tmp/foo.txt")->filehandle($mode, $binmode);
#pod     $fh = path("/tmp/foo.txt")->filehandle({ locked => 1 }, $mode, $binmode);
#pod
#pod Returns an open file handle.  The C<$mode> argument must be a Perl-style
#pod read/write mode string ("<" ,">", "<<", etc.).  If a C<$binmode>
#pod is given, it is set during the C<open> call.
#pod
#pod An optional hash reference may be used to pass options.  The only option is
#pod C<locked>.  If true, handles opened for writing, appending or read-write are
#pod locked with C<LOCK_EX>; otherwise, they are locked with C<LOCK_SH>.  When using
#pod C<locked>, ">" or "+>" modes will delay truncation until after the lock is
#pod acquired.
#pod
#pod See C<openr>, C<openw>, C<openrw>, and C<opena> for sugar.
#pod
#pod =cut

# Note: must put binmode on open line, not subsequent binmode() call, so things
# like ":unix" actually stop perlio/crlf from being added

sub filehandle {
    my ( $self, @args ) = @_;
    my $args = ( @args && ref $args[0] eq 'HASH' ) ? shift @args : {};
    $args = _get_args( $args, qw/locked/ );
    my ( $opentype, $binmode ) = @args;

    $opentype = "<" unless defined $opentype;
    Carp::croak("Invalid file mode '$opentype'")
      unless grep { $opentype eq $_ } qw/< +< > +> >> +>>/;

    $binmode = ( ( caller(0) )[10] || {} )->{ 'open' . substr( $opentype, -1, 1 ) }
      unless defined $binmode;
    $binmode = "" unless defined $binmode;

    my ( $fh, $lock, $trunc );
    if ( $HAS_FLOCK && $args->{locked} ) {
        require Fcntl;
        # truncating file modes shouldn't truncate until lock acquired
        if ( grep { $opentype eq $_ } qw( > +> ) ) {
            # sysopen in write mode without truncation
            my $flags = $opentype eq ">" ? Fcntl::O_WRONLY() : Fcntl::O_RDWR();
            $flags |= Fcntl::O_CREAT();
            sysopen( $fh, $self->[PATH], $flags ) or $self->_throw("sysopen");

            # fix up the binmode since sysopen() can't specify layers like
            # open() and binmode() can't start with just :unix like open()
            if ( $binmode =~ s/^:unix// ) {
                # eliminate pseudo-layers
                binmode( $fh, ":raw" ) or $self->_throw("binmode (:raw)");
                # strip off real layers until only :unix is left
                while ( 1 < ( my $layers =()= PerlIO::get_layers( $fh, output => 1 ) ) ) {
                    binmode( $fh, ":pop" ) or $self->_throw("binmode (:pop)");
                }
            }

            # apply any remaining binmode layers
            if ( length $binmode ) {
                binmode( $fh, $binmode ) or $self->_throw("binmode ($binmode)");
            }

            # ask for lock and truncation
            $lock  = Fcntl::LOCK_EX();
            $trunc = 1;
        }
        elsif ( $^O eq 'aix' && $opentype eq "<" ) {
            # AIX can only lock write handles, so upgrade to RW and LOCK_EX if
            # the file is writable; otherwise give up on locking.  N.B.
            # checking -w before open to determine the open mode is an
            # unavoidable race condition
            if ( -w $self->[PATH] ) {
                $opentype = "+<";
                $lock     = Fcntl::LOCK_EX();
            }
        }
        else {
            $lock = $opentype eq "<" ? Fcntl::LOCK_SH() : Fcntl::LOCK_EX();
        }
    }

    unless ($fh) {
        my $mode = $opentype . $binmode;
        open $fh, $mode, $self->[PATH] or $self->_throw("open ($mode)");
    }

    do { flock( $fh, $lock ) or $self->_throw("flock ($lock)") } if $lock;
    do { truncate( $fh, 0 ) or $self->_throw("truncate") } if $trunc;

    return $fh;
}

#pod =method is_absolute, is_relative
#pod
#pod     if ( path("/tmp")->is_absolute ) { ... }
#pod     if ( path("/tmp")->is_relative ) { ... }
#pod
#pod Booleans for whether the path appears absolute or relative.
#pod
#pod =cut

sub is_absolute { substr( $_[0]->dirname, 0, 1 ) eq '/' }

sub is_relative { substr( $_[0]->dirname, 0, 1 ) ne '/' }

#pod =method is_rootdir
#pod
#pod     while ( ! $path->is_rootdir ) {
#pod         $path = $path->parent;
#pod         ...
#pod     }
#pod
#pod Boolean for whether the path is the root directory of the volume.  I.e. the
#pod C<dirname> is C<q[/]> and the C<basename> is C<q[]>.
#pod
#pod This works even on C<MSWin32> with drives and UNC volumes:
#pod
#pod     path("C:/")->is_rootdir;             # true
#pod     path("//server/share/")->is_rootdir; #true
#pod
#pod =cut

sub is_rootdir {
    my ($self) = @_;
    $self->_splitpath unless defined $self->[DIR];
    return $self->[DIR] eq '/' && $self->[FILE] eq '';
}

#pod =method iterator
#pod
#pod     $iter = path("/tmp")->iterator( \%options );
#pod
#pod Returns a code reference that walks a directory lazily.  Each invocation
#pod returns a C<Path::Tiny> object or undef when the iterator is exhausted.
#pod
#pod     $iter = path("/tmp")->iterator;
#pod     while ( $path = $iter->() ) {
#pod         ...
#pod     }
#pod
#pod The current and parent directory entries ("." and "..") will not
#pod be included.
#pod
#pod If the C<recurse> option is true, the iterator will walk the directory
#pod recursively, breadth-first.  If the C<follow_symlinks> option is also true,
#pod directory links will be followed recursively.  There is no protection against
#pod loops when following links. If a directory is not readable, it will not be
#pod followed.
#pod
#pod The default is the same as:
#pod
#pod     $iter = path("/tmp")->iterator( {
#pod         recurse         => 0,
#pod         follow_symlinks => 0,
#pod     } );
#pod
#pod For a more powerful, recursive iterator with built-in loop avoidance, see
#pod L<Path::Iterator::Rule>.
#pod
#pod =cut

sub iterator {
    my $self = shift;
    my $args = _get_args( shift, qw/recurse follow_symlinks/ );
    my @dirs = $self;
    my $current;
    return sub {
        my $next;
        while (@dirs) {
            if ( ref $dirs[0] eq 'Path::Tiny' ) {
                if ( !-r $dirs[0] ) {
                    # Directory is missing or not readable, so skip it.  There
                    # is still a race condition possible between the check and
                    # the opendir, but we can't easily differentiate between
                    # error cases that are OK to skip and those that we want
                    # to be exceptions, so we live with the race and let opendir
                    # be fatal.
                    shift @dirs and next;
                }
                $current = $dirs[0];
                my $dh;
                opendir( $dh, $current->[PATH] )
                  or $self->_throw( 'opendir', $current->[PATH] );
                $dirs[0] = $dh;
                if ( -l $current->[PATH] && !$args->{follow_symlinks} ) {
                    # Symlink attack! It was a real dir, but is now a symlink!
                    # N.B. we check *after* opendir so the attacker has to win
                    # two races: replace dir with symlink before opendir and
                    # replace symlink with dir before -l check above
                    shift @dirs and next;
                }
            }
            while ( defined( $next = readdir $dirs[0] ) ) {
                next if $next eq '.' || $next eq '..';
                my $path = $current->child($next);
                push @dirs, $path
                  if $args->{recurse} && -d $path && !( !$args->{follow_symlinks} && -l $path );
                return $path;
            }
            shift @dirs;
        }
        return;
    };
}

#pod =method lines, lines_raw, lines_utf8
#pod
#pod     @contents = path("/tmp/foo.txt")->lines;
#pod     @contents = path("/tmp/foo.txt")->lines(\%options);
#pod     @contents = path("/tmp/foo.txt")->lines_raw;
#pod     @contents = path("/tmp/foo.txt")->lines_utf8;
#pod
#pod     @contents = path("/tmp/foo.txt")->lines( { chomp => 1, count => 4 } );
#pod
#pod Returns a list of lines from a file.  Optionally takes a hash-reference of
#pod options.  Valid options are C<binmode>, C<count> and C<chomp>.  If C<binmode>
#pod is provided, it will be set on the handle prior to reading.  If C<count> is
#pod provided, up to that many lines will be returned. If C<chomp> is set, any
#pod end-of-line character sequences (C<CR>, C<CRLF>, or C<LF>) will be removed
#pod from the lines returned.
#pod
#pod Because the return is a list, C<lines> in scalar context will return the number
#pod of lines (and throw away the data).
#pod
#pod     $number_of_lines = path("/tmp/foo.txt")->lines;
#pod
#pod C<lines_raw> is like C<lines> with a C<binmode> of C<:raw>.  We use C<:raw>
#pod instead of C<:unix> so PerlIO buffering can manage reading by line.
#pod
#pod C<lines_utf8> is like C<lines> with a C<binmode> of
#pod C<:raw:encoding(UTF-8)>.  If L<Unicode::UTF8> 0.58+ is installed, a raw
#pod UTF-8 slurp will be done and then the lines will be split.  This is
#pod actually faster than relying on C<:encoding(UTF-8)>, though a bit memory
#pod intensive.  If memory use is a concern, consider C<openr_utf8> and
#pod iterating directly on the handle.
#pod
#pod =cut

sub lines {
    my $self    = shift;
    my $args    = _get_args( shift, qw/binmode chomp count/ );
    my $binmode = $args->{binmode};
    $binmode = ( ( caller(0) )[10] || {} )->{'open<'} unless defined $binmode;
    my $fh = $self->filehandle( { locked => 1 }, "<", $binmode );
    my $chomp = $args->{chomp};
    # XXX more efficient to read @lines then chomp(@lines) vs map?
    if ( $args->{count} ) {
        my ( @result, $counter );
        while ( my $line = <$fh> ) {
            $line =~ s/(?:\x{0d}?\x{0a}|\x{0d})$// if $chomp;
            push @result, $line;
            last if ++$counter == $args->{count};
        }
        return @result;
    }
    elsif ($chomp) {
        return map { s/(?:\x{0d}?\x{0a}|\x{0d})$//; $_ } <$fh>; ## no critic
    }
    else {
        return wantarray ? <$fh> : ( my $count =()= <$fh> );
    }
}

sub lines_raw {
    my $self = shift;
    my $args = _get_args( shift, qw/binmode chomp count/ );
    if ( $args->{chomp} && !$args->{count} ) {
        return split /\n/, slurp_raw($self);                    ## no critic
    }
    else {
        $args->{binmode} = ":raw";
        return lines( $self, $args );
    }
}

sub lines_utf8 {
    my $self = shift;
    my $args = _get_args( shift, qw/binmode chomp count/ );
    if (   ( defined($HAS_UU) ? $HAS_UU : $HAS_UU = _check_UU() )
        && $args->{chomp}
        && !$args->{count} )
    {
        return split /(?:\x{0d}?\x{0a}|\x{0d})/, slurp_utf8($self); ## no critic
    }
    else {
        $args->{binmode} = ":raw:encoding(UTF-8)";
        return lines( $self, $args );
    }
}

#pod =method mkpath
#pod
#pod     path("foo/bar/baz")->mkpath;
#pod     path("foo/bar/baz")->mkpath( \%options );
#pod
#pod Like calling C<make_path> from L<File::Path>.  An optional hash reference
#pod is passed through to C<make_path>.  Errors will be trapped and an exception
#pod thrown.  Returns the list of directories created or an empty list if
#pod the directories already exist, just like C<make_path>.
#pod
#pod =cut

sub mkpath {
    my ( $self, $args ) = @_;
    $args = {} unless ref $args eq 'HASH';
    my $err;
    $args->{err} = \$err unless defined $args->{err};
    require File::Path;
    my @dirs = File::Path::make_path( $self->[PATH], $args );
    if ( $err && @$err ) {
        my ( $file, $message ) = %{ $err->[0] };
        Carp::croak("mkpath failed for $file: $message");
    }
    return @dirs;
}

#pod =method move
#pod
#pod     path("foo.txt")->move("bar.txt");
#pod
#pod Just like C<rename>.
#pod
#pod =cut

sub move {
    my ( $self, $dst ) = @_;

    return rename( $self->[PATH], $dst )
      || $self->_throw( 'rename', $self->[PATH] . "' -> '$dst'" );
}

#pod =method openr, openw, openrw, opena
#pod
#pod     $fh = path("foo.txt")->openr($binmode);  # read
#pod     $fh = path("foo.txt")->openr_raw;
#pod     $fh = path("foo.txt")->openr_utf8;
#pod
#pod     $fh = path("foo.txt")->openw($binmode);  # write
#pod     $fh = path("foo.txt")->openw_raw;
#pod     $fh = path("foo.txt")->openw_utf8;
#pod
#pod     $fh = path("foo.txt")->opena($binmode);  # append
#pod     $fh = path("foo.txt")->opena_raw;
#pod     $fh = path("foo.txt")->opena_utf8;
#pod
#pod     $fh = path("foo.txt")->openrw($binmode); # read/write
#pod     $fh = path("foo.txt")->openrw_raw;
#pod     $fh = path("foo.txt")->openrw_utf8;
#pod
#pod Returns a file handle opened in the specified mode.  The C<openr> style methods
#pod take a single C<binmode> argument.  All of the C<open*> methods have
#pod C<open*_raw> and C<open*_utf8> equivalents that use C<:raw> and
#pod C<:raw:encoding(UTF-8)>, respectively.
#pod
#pod An optional hash reference may be used to pass options.  The only option is
#pod C<locked>.  If true, handles opened for writing, appending or read-write are
#pod locked with C<LOCK_EX>; otherwise, they are locked for C<LOCK_SH>.
#pod
#pod     $fh = path("foo.txt")->openrw_utf8( { locked => 1 } );
#pod
#pod See L</filehandle> for more on locking.
#pod
#pod =cut

# map method names to corresponding open mode
my %opens = (
    opena  => ">>",
    openr  => "<",
    openw  => ">",
    openrw => "+<"
);

while ( my ( $k, $v ) = each %opens ) {
    no strict 'refs';
    # must check for lexical IO mode hint
    *{$k} = sub {
        my ( $self, @args ) = @_;
        my $args = ( @args && ref $args[0] eq 'HASH' ) ? shift @args : {};
        $args = _get_args( $args, qw/locked/ );
        my ($binmode) = @args;
        $binmode = ( ( caller(0) )[10] || {} )->{ 'open' . substr( $v, -1, 1 ) }
          unless defined $binmode;
        $self->filehandle( $args, $v, $binmode );
    };
    *{ $k . "_raw" } = sub {
        my ( $self, @args ) = @_;
        my $args = ( @args && ref $args[0] eq 'HASH' ) ? shift @args : {};
        $args = _get_args( $args, qw/locked/ );
        $self->filehandle( $args, $v, ":raw" );
    };
    *{ $k . "_utf8" } = sub {
        my ( $self, @args ) = @_;
        my $args = ( @args && ref $args[0] eq 'HASH' ) ? shift @args : {};
        $args = _get_args( $args, qw/locked/ );
        $self->filehandle( $args, $v, ":raw:encoding(UTF-8)" );
    };
}

#pod =method parent
#pod
#pod     $parent = path("foo/bar/baz")->parent; # foo/bar
#pod     $parent = path("foo/wibble.txt")->parent; # foo
#pod
#pod     $parent = path("foo/bar/baz")->parent(2); # foo
#pod
#pod Returns a C<Path::Tiny> object corresponding to the parent directory of the
#pod original directory or file. An optional positive integer argument is the number
#pod of parent directories upwards to return.  C<parent> by itself is equivalent to
#pod C<parent(1)>.
#pod
#pod =cut

# XXX this is ugly and coverage is incomplete.  I think it's there for windows
# so need to check coverage there and compare
sub parent {
    my ( $self, $level ) = @_;
    $level = 1 unless defined $level && $level > 0;
    $self->_splitpath unless defined $self->[FILE];
    my $parent;
    if ( length $self->[FILE] ) {
        if ( $self->[FILE] eq '.' || $self->[FILE] eq ".." ) {
            $parent = path( $self->[PATH] . "/.." );
        }
        else {
            $parent = path( _non_empty( $self->[VOL] . $self->[DIR] ) );
        }
    }
    elsif ( length $self->[DIR] ) {
        # because of symlinks, any internal updir requires us to
        # just add more updirs at the end
        if ( $self->[DIR] =~ m{(?:^\.\./|/\.\./|/\.\.$)} ) {
            $parent = path( $self->[VOL] . $self->[DIR] . "/.." );
        }
        else {
            ( my $dir = $self->[DIR] ) =~ s{/[^\/]+/$}{/};
            $parent = path( $self->[VOL] . $dir );
        }
    }
    else {
        $parent = path( _non_empty( $self->[VOL] ) );
    }
    return $level == 1 ? $parent : $parent->parent( $level - 1 );
}

sub _non_empty {
    my ($string) = shift;
    return ( ( defined($string) && length($string) ) ? $string : "." );
}

#pod =method realpath
#pod
#pod     $real = path("/baz/foo/../bar")->realpath;
#pod     $real = path("foo/../bar")->realpath;
#pod
#pod Returns a new C<Path::Tiny> object with all symbolic links and upward directory
#pod parts resolved using L<Cwd>'s C<realpath>.  Compared to C<absolute>, this is
#pod more expensive as it must actually consult the filesystem.
#pod
#pod If the path can't be resolved (e.g. if it includes directories that don't exist),
#pod an exception will be thrown:
#pod
#pod     $real = path("doesnt_exist/foo")->realpath; # dies
#pod
#pod =cut

sub realpath {
    my $self = shift;
    require Cwd;
    my $realpath = eval {
        local $SIG{__WARN__} = sub { }; # (sigh) pure-perl CWD can carp
        Cwd::realpath( $self->[PATH] );
    };
    $self->_throw("resolving realpath") unless defined $realpath and length $realpath;
    return path($realpath);
}

#pod =method relative
#pod
#pod     $rel = path("/tmp/foo/bar")->relative("/tmp"); # foo/bar
#pod
#pod Returns a C<Path::Tiny> object with a relative path name.
#pod Given the trickiness of this, it's a thin wrapper around
#pod C<< File::Spec->abs2rel() >>.
#pod
#pod =cut

# Easy to get wrong, so wash it through File::Spec (sigh)
sub relative { path( File::Spec->abs2rel( $_[0]->[PATH], $_[1] ) ) }

#pod =method remove
#pod
#pod     path("foo.txt")->remove;
#pod
#pod B<Note: as of 0.012, remove only works on files>.
#pod
#pod This is just like C<unlink>, except for its error handling: if the path does
#pod not exist, it returns false; if deleting the file fails, it throws an
#pod exception.
#pod
#pod =cut

sub remove {
    my $self = shift;

    return 0 if !-e $self->[PATH] && !-l $self->[PATH];

    return unlink( $self->[PATH] ) || $self->_throw('unlink');
}

#pod =method remove_tree
#pod
#pod     # directory
#pod     path("foo/bar/baz")->remove_tree;
#pod     path("foo/bar/baz")->remove_tree( \%options );
#pod     path("foo/bar/baz")->remove_tree( { safe => 0 } ); # force remove
#pod
#pod Like calling C<remove_tree> from L<File::Path>, but defaults to C<safe> mode.
#pod An optional hash reference is passed through to C<remove_tree>.  Errors will be
#pod trapped and an exception thrown.  Returns the number of directories deleted,
#pod just like C<remove_tree>.
#pod
#pod If you want to remove a directory only if it is empty, use the built-in
#pod C<rmdir> function instead.
#pod
#pod     rmdir path("foo/bar/baz/");
#pod
#pod =cut

sub remove_tree {
    my ( $self, $args ) = @_;
    return 0 if !-e $self->[PATH] && !-l $self->[PATH];
    $args = {} unless ref $args eq 'HASH';
    my $err;
    $args->{err}  = \$err unless defined $args->{err};
    $args->{safe} = 1     unless defined $args->{safe};
    require File::Path;
    my $count = File::Path::remove_tree( $self->[PATH], $args );

    if ( $err && @$err ) {
        my ( $file, $message ) = %{ $err->[0] };
        Carp::croak("remove_tree failed for $file: $message");
    }
    return $count;
}

#pod =method slurp, slurp_raw, slurp_utf8
#pod
#pod     $data = path("foo.txt")->slurp;
#pod     $data = path("foo.txt")->slurp( {binmode => ":raw"} );
#pod     $data = path("foo.txt")->slurp_raw;
#pod     $data = path("foo.txt")->slurp_utf8;
#pod
#pod Reads file contents into a scalar.  Takes an optional hash reference may be
#pod used to pass options.  The only option is C<binmode>, which is passed to
#pod C<binmode()> on the handle used for reading.
#pod
#pod C<slurp_raw> is like C<slurp> with a C<binmode> of C<:unix> for
#pod a fast, unbuffered, raw read.
#pod
#pod C<slurp_utf8> is like C<slurp> with a C<binmode> of
#pod C<:unix:encoding(UTF-8)>.  If L<Unicode::UTF8> 0.58+ is installed, a raw
#pod slurp will be done instead and the result decoded with C<Unicode::UTF8>.
#pod This is just as strict and is roughly an order of magnitude faster than
#pod using C<:encoding(UTF-8)>.
#pod
#pod =cut

sub slurp {
    my $self    = shift;
    my $args    = _get_args( shift, qw/binmode/ );
    my $binmode = $args->{binmode};
    $binmode = ( ( caller(0) )[10] || {} )->{'open<'} unless defined $binmode;
    my $fh = $self->filehandle( { locked => 1 }, "<", $binmode );
    if ( ( defined($binmode) ? $binmode : "" ) eq ":unix"
        and my $size = -s $fh )
    {
        my $buf;
        read $fh, $buf, $size; # File::Slurp in a nutshell
        return $buf;
    }
    else {
        local $/;
        return scalar <$fh>;
    }
}

sub slurp_raw { $_[1] = { binmode => ":unix" }; goto &slurp }

sub slurp_utf8 {
    if ( defined($HAS_UU) ? $HAS_UU : $HAS_UU = _check_UU() ) {
        return Unicode::UTF8::decode_utf8( slurp( $_[0], { binmode => ":unix" } ) );
    }
    else {
        $_[1] = { binmode => ":raw:encoding(UTF-8)" };
        goto &slurp;
    }
}

#pod =method spew, spew_raw, spew_utf8
#pod
#pod     path("foo.txt")->spew(@data);
#pod     path("foo.txt")->spew(\@data);
#pod     path("foo.txt")->spew({binmode => ":raw"}, @data);
#pod     path("foo.txt")->spew_raw(@data);
#pod     path("foo.txt")->spew_utf8(@data);
#pod
#pod Writes data to a file atomically.  The file is written to a temporary file in
#pod the same directory, then renamed over the original.  An optional hash reference
#pod may be used to pass options.  The only option is C<binmode>, which is passed to
#pod C<binmode()> on the handle used for writing.
#pod
#pod C<spew_raw> is like C<spew> with a C<binmode> of C<:unix> for a fast,
#pod unbuffered, raw write.
#pod
#pod C<spew_utf8> is like C<spew> with a C<binmode> of C<:unix:encoding(UTF-8)>.
#pod If L<Unicode::UTF8> 0.58+ is installed, a raw spew will be done instead on
#pod the data encoded with C<Unicode::UTF8>.
#pod
#pod =cut

# XXX add "unsafe" option to disable flocking and atomic?  Check benchmarks on append() first.
sub spew {
    my ( $self, @data ) = @_;
    my $args = ( @data && ref $data[0] eq 'HASH' ) ? shift @data : {};
    $args = _get_args( $args, qw/binmode/ );
    my $binmode = $args->{binmode};
    # get default binmode from caller's lexical scope (see "perldoc open")
    $binmode = ( ( caller(0) )[10] || {} )->{'open>'} unless defined $binmode;
    my $temp = path( $self->[PATH] . $$ . int( rand( 2**31 ) ) );
    my $fh = $temp->filehandle( { locked => 1 }, ">", $binmode );
    print {$fh} map { ref eq 'ARRAY' ? @$_ : $_ } @data;
    close $fh or $self->_throw( 'close', $temp->[PATH] );

    # spewing need to follow the link
    # and replace the destination instead
    my $resolved_path = $self->[PATH];
    $resolved_path = readlink $resolved_path while -l $resolved_path;
    return $temp->move($resolved_path);
}

sub spew_raw { splice @_, 1, 0, { binmode => ":unix" }; goto &spew }

sub spew_utf8 {
    if ( defined($HAS_UU) ? $HAS_UU : $HAS_UU = _check_UU() ) {
        my $self = shift;
        spew( $self, { binmode => ":unix" }, map { Unicode::UTF8::encode_utf8($_) } @_ );
    }
    else {
        splice @_, 1, 0, { binmode => ":unix:encoding(UTF-8)" };
        goto &spew;
    }
}

#pod =method stat, lstat
#pod
#pod     $stat = path("foo.txt")->stat;
#pod     $stat = path("/some/symlink")->lstat;
#pod
#pod Like calling C<stat> or C<lstat> from L<File::stat>.
#pod
#pod =cut

# XXX break out individual stat() components as subs?
sub stat {
    my $self = shift;
    require File::stat;
    return File::stat::stat( $self->[PATH] ) || $self->_throw('stat');
}

sub lstat {
    my $self = shift;
    require File::stat;
    return File::stat::lstat( $self->[PATH] ) || $self->_throw('lstat');
}

#pod =method stringify
#pod
#pod     $path = path("foo.txt");
#pod     say $path->stringify; # same as "$path"
#pod
#pod Returns a string representation of the path.  Unlike C<canonpath>, this method
#pod returns the path standardized with Unix-style C</> directory separators.
#pod
#pod =cut

sub stringify { $_[0]->[PATH] }

#pod =method subsumes
#pod
#pod     path("foo/bar")->subsumes("foo/bar/baz"); # true
#pod     path("/foo/bar")->subsumes("/foo/baz");   # false
#pod
#pod Returns true if the first path is a prefix of the second path at a directory
#pod boundary.
#pod
#pod This B<does not> resolve parent directory entries (C<..>) or symlinks:
#pod
#pod     path("foo/bar")->subsumes("foo/bar/../baz"); # true
#pod
#pod If such things are important to you, ensure that both paths are resolved to
#pod the filesystem with C<realpath>:
#pod
#pod     my $p1 = path("foo/bar")->realpath;
#pod     my $p2 = path("foo/bar/../baz")->realpath;
#pod     if ( $p1->subsumes($p2) ) { ... }
#pod
#pod =cut

sub subsumes {
    my $self = shift;
    Carp::croak("subsumes() requires a defined, positive-length argument")
      unless defined $_[0];
    my $other = path(shift);

    # normalize absolute vs relative
    if ( $self->is_absolute && !$other->is_absolute ) {
        $other = $other->absolute;
    }
    elsif ( $other->is_absolute && !$self->is_absolute ) {
        $self = $self->absolute;
    }

    # normalize volume vs non-volume; do this after absolute path
    # adjustments above since that might add volumes already
    if ( length $self->volume && !length $other->volume ) {
        $other = $other->absolute;
    }
    elsif ( length $other->volume && !length $self->volume ) {
        $self = $self->absolute;
    }

    if ( $self->[PATH] eq '.' ) {
        return !!1; # cwd subsumes everything relative
    }
    elsif ( $self->is_rootdir ) {
        # a root directory ("/", "c:/") already ends with a separator
        return $other->[PATH] =~ m{^\Q$self->[PATH]\E};
    }
    else {
        # exact match or prefix breaking at a separator
        return $other->[PATH] =~ m{^\Q$self->[PATH]\E(?:/|$)};
    }
}

#pod =method touch
#pod
#pod     path("foo.txt")->touch;
#pod     path("foo.txt")->touch($epoch_secs);
#pod
#pod Like the Unix C<touch> utility.  Creates the file if it doesn't exist, or else
#pod changes the modification and access times to the current time.  If the first
#pod argument is the epoch seconds then it will be used.
#pod
#pod Returns the path object so it can be easily chained with spew:
#pod
#pod     path("foo.txt")->touch->spew( $content );
#pod
#pod =cut

sub touch {
    my ( $self, $epoch ) = @_;
    if ( !-e $self->[PATH] ) {
        my $fh = $self->openw;
        close $fh or $self->_throw('close');
    }
    $epoch = defined($epoch) ? $epoch : time();
    utime $epoch, $epoch, $self->[PATH]
      or $self->_throw("utime ($epoch)");
    return $self;
}

#pod =method touchpath
#pod
#pod     path("bar/baz/foo.txt")->touchpath;
#pod
#pod Combines C<mkpath> and C<touch>.  Creates the parent directory if it doesn't exist,
#pod before touching the file.  Returns the path object like C<touch> does.
#pod
#pod =cut

sub touchpath {
    my ($self) = @_;
    my $parent = $self->parent;
    $parent->mkpath unless $parent->exists;
    $self->touch;
}

#pod =method volume
#pod
#pod     $vol = path("/tmp/foo.txt")->volume;   # ""
#pod     $vol = path("C:/tmp/foo.txt")->volume; # "C:"
#pod
#pod Returns the volume portion of the path.  This is equivalent
#pod equivalent to what L<File::Spec> would give from C<splitpath> and thus
#pod usually is the empty string on Unix-like operating systems or the
#pod drive letter for an absolute path on C<MSWin32>.
#pod
#pod =cut

sub volume {
    my ($self) = @_;
    $self->_splitpath unless defined $self->[VOL];
    return $self->[VOL];
}

package Path::Tiny::Error;

our @CARP_NOT = qw/Path::Tiny/;

use overload ( q{""} => sub { (shift)->{msg} }, fallback => 1 );

sub throw {
    my ( $class, $op, $file, $err ) = @_;
    chomp( my $trace = Carp::shortmess );
    my $msg = "Error $op on '$file': $err$trace\n";
    die bless { op => $op, file => $file, err => $err, msg => $msg }, $class;
}

1;


# vim: ts=4 sts=4 sw=4 et:

__END__

=pod

=encoding UTF-8

=head1 NAME

Path::Tiny - File path utility

=head1 VERSION

version 0.057

=head1 SYNOPSIS

  use Path::Tiny;

  # creating Path::Tiny objects

  $dir = path("/tmp");
  $foo = path("foo.txt");

  $subdir = $dir->child("foo");
  $bar = $subdir->child("bar.txt");

  # stringifies as cleaned up path

  $file = path("./foo.txt");
  print $file; # "foo.txt"

  # reading files

  $guts = $file->slurp;
  $guts = $file->slurp_utf8;

  @lines = $file->lines;
  @lines = $file->lines_utf8;

  $head = $file->lines( {count => 1} );

  # writing files

  $bar->spew( @data );
  $bar->spew_utf8( @data );

  # reading directories

  for ( $dir->children ) { ... }

  $iter = $dir->iterator;
  while ( my $next = $iter->() ) { ... }

=head1 DESCRIPTION

This module provide a small, fast utility for working with file paths.  It is
friendlier to use than L<File::Spec> and provides easy access to functions from
several other core file handling modules.  It aims to be smaller and faster
than many alternatives on CPAN while helping people do many common things in
consistent and less error-prone ways.

Path::Tiny does not try to work for anything except Unix-like and Win32
platforms.  Even then, it might break if you try something particularly obscure
or tortuous.  (Quick!  What does this mean:
C<< ///../../..//./././a//b/.././c/././ >>?  And how does it differ on Win32?)

All paths are forced to have Unix-style forward slashes.  Stringifying
the object gives you back the path (after some clean up).

File input/output methods C<flock> handles before reading or writing,
as appropriate (if supported by the platform).

The C<*_utf8> methods (C<slurp_utf8>, C<lines_utf8>, etc.) operate in raw mode.
On Windows, that means they will not have CRLF translation from the C<:crlf> IO
layer.  Installing L<Unicode::UTF8> 0.58 or later will speed up C<*_utf8>
situations in many cases and is highly recommended.

=head1 CONSTRUCTORS

=head2 path

    $path = path("foo/bar");
    $path = path("/tmp", "file.txt"); # list
    $path = path(".");                # cwd
    $path = path("~user/file.txt");   # tilde processing

Constructs a C<Path::Tiny> object.  It doesn't matter if you give a file or
directory path.  It's still up to you to call directory-like methods only on
directories and file-like methods only on files.  This function is exported
automatically by default.

The first argument must be defined and have non-zero length or an exception
will be thrown.  This prevents subtle, dangerous errors with code like
C<< path( maybe_undef() )->remove_tree >>.

If the first component of the path is a tilde ('~') then the component will be
replaced with the output of C<glob('~')>.  If the first component of the path
is a tilde followed by a user name then the component will be replaced with
output of C<glob('~username')>.  Behaviour for non-existent users depends on
the output of C<glob> on the system.

On Windows, if the path consists of a drive identifier without a path component
(C<C:> or C<D:>), it will be expanded to the absolute path of the current
directory on that volume using C<Cwd::getdcwd()>.

If called with a single C<Path::Tiny> argument, the original is returned unless
the original is holding a temporary file or directory reference in which case a
stringified copy is made.

    $path = path("foo/bar");
    $temp = Path::Tiny->tempfile;

    $p2 = path($path); # like $p2 = $path
    $t2 = path($temp); # like $t2 = path( "$temp" )

This optimizes copies without proliferating references unexpectedly if a copy is
made by code outside your control.

=head2 new

    $path = Path::Tiny->new("foo/bar");

This is just like C<path>, but with method call overhead.  (Why would you
do that?)

=head2 cwd

    $path = Path::Tiny->cwd; # path( Cwd::getcwd )
    $path = cwd; # optional export

Gives you the absolute path to the current directory as a C<Path::Tiny> object.
This is slightly faster than C<< path(".")->absolute >>.

C<cwd> may be exported on request and used as a function instead of as a
method.

=head2 rootdir

    $path = Path::Tiny->rootdir; # /
    $path = rootdir;             # optional export 

Gives you C<< File::Spec->rootdir >> as a C<Path::Tiny> object if you're too
picky for C<path("/")>.

C<rootdir> may be exported on request and used as a function instead of as a
method.

=head2 tempfile, tempdir

    $temp = Path::Tiny->tempfile( @options );
    $temp = Path::Tiny->tempdir( @options );
    $temp = tempfile( @options ); # optional export
    $temp = tempdir( @options );  # optional export

C<tempfile> passes the options to C<< File::Temp->new >> and returns a C<Path::Tiny>
object with the file name.  The C<TMPDIR> option is enabled by default.

The resulting C<File::Temp> object is cached. When the C<Path::Tiny> object is
destroyed, the C<File::Temp> object will be as well.

C<File::Temp> annoyingly requires you to specify a custom template in slightly
different ways depending on which function or method you call, but
C<Path::Tiny> lets you ignore that and can take either a leading template or a
C<TEMPLATE> option and does the right thing.

    $temp = Path::Tiny->tempfile( "customXXXXXXXX" );             # ok
    $temp = Path::Tiny->tempfile( TEMPLATE => "customXXXXXXXX" ); # ok

The tempfile path object will normalized to have an absolute path, even if
created in a relative directory using C<DIR>.

C<tempdir> is just like C<tempfile>, except it calls
C<< File::Temp->newdir >> instead.

Both C<tempfile> and C<tempdir> may be exported on request and used as
functions instead of as methods.

=head1 METHODS

=head2 absolute

    $abs = path("foo/bar")->absolute;
    $abs = path("foo/bar")->absolute("/tmp");

Returns a new C<Path::Tiny> object with an absolute path (or itself if already
absolute).  Unless an argument is given, the current directory is used as the
absolute base path.  The argument must be absolute or you won't get an absolute
result.

This will not resolve upward directories ("foo/../bar") unless C<canonpath>
in L<File::Spec> would normally do so on your platform.  If you need them
resolved, you must call the more expensive C<realpath> method instead.

On Windows, an absolute path without a volume component will have it added
based on the current drive.

=head2 append, append_raw, append_utf8

    path("foo.txt")->append(@data);
    path("foo.txt")->append(\@data);
    path("foo.txt")->append({binmode => ":raw"}, @data);
    path("foo.txt")->append_raw(@data);
    path("foo.txt")->append_utf8(@data);

Appends data to a file.  The file is locked with C<flock> prior to writing.  An
optional hash reference may be used to pass options.  The only option is
C<binmode>, which is passed to C<binmode()> on the handle used for writing.

C<append_raw> is like C<append> with a C<binmode> of C<:unix> for fast,
unbuffered, raw write.

C<append_utf8> is like C<append> with a C<binmode> of
C<:unix:encoding(UTF-8)>.  If L<Unicode::UTF8> 0.58+ is installed, a raw
append will be done instead on the data encoded with C<Unicode::UTF8>.

=head2 basename

    $name = path("foo/bar.txt")->basename;        # bar.txt
    $name = path("foo.txt")->basename('.txt');    # foo
    $name = path("foo.txt")->basename(qr/.txt/);  # foo
    $name = path("foo.txt")->basename(@suffixes);

Returns the file portion or last directory portion of a path.

Given a list of suffixes as strings or regular expressions, any that match at
the end of the file portion or last directory portion will be removed before
the result is returned.

=head2 canonpath

    $canonical = path("foo/bar")->canonpath; # foo\bar on Windows

Returns a string with the canonical format of the path name for
the platform.  In particular, this means directory separators
will be C<\> on Windows.

=head2 child

    $file = path("/tmp")->child("foo.txt"); # "/tmp/foo.txt"
    $file = path("/tmp")->child(@parts);

Returns a new C<Path::Tiny> object relative to the original.  Works
like C<catfile> or C<catdir> from File::Spec, but without caring about
file or directories.

=head2 children

    @paths = path("/tmp")->children;
    @paths = path("/tmp")->children( qr/\.txt$/ );

Returns a list of C<Path::Tiny> objects for all files and directories
within a directory.  Excludes "." and ".." automatically.

If an optional C<qr//> argument is provided, it only returns objects for child
names that match the given regular expression.  Only the base name is used
for matching:

    @paths = path("/tmp")->children( qr/^foo/ );
    # matches children like the glob foo*

=head2 chmod

    path("foo.txt")->chmod(0777);
    path("foo.txt")->chmod("0755");
    path("foo.txt")->chmod("go-w");
    path("foo.txt")->chmod("a=r,u+wx");

Sets file or directory permissions.  The argument can be a numeric mode, a
octal string beginning with a "0" or a limited subset of the symbolic mode use
by F</bin/chmod>.

The symbolic mode must be a comma-delimited list of mode clauses.  Clauses must
match C<< qr/\A([augo]+)([=+-])([rwx]+)\z/ >>, which defines "who", "op" and
"perms" parameters for each clause.  Unlike F</bin/chmod>, all three parameters
are required for each clause, multiple ops are not allowed and permissions
C<stugoX> are not supported.  (See L<File::chmod> for more complex needs.)

=head2 copy

    path("/tmp/foo.txt")->copy("/tmp/bar.txt");

Copies a file using L<File::Copy>'s C<copy> function.

=head2 digest

    $obj = path("/tmp/foo.txt")->digest;        # SHA-256
    $obj = path("/tmp/foo.txt")->digest("MD5"); # user-selected
    $obj = path("/tmp/foo.txt")->digest( { chunk_size => 1e6 }, "MD5" );

Returns a hexadecimal digest for a file.  An optional hash reference of options may
be given.  The only option is C<chunk_size>.  If C<chunk_size> is given, that many
bytes will be read at a time.  If not provided, the entire file will be slurped
into memory to compute the digest.

Any subsequent arguments are passed to the constructor for L<Digest> to select
an algorithm.  If no arguments are given, the default is SHA-256.

=head2 dirname (deprecated)

    $name = path("/tmp/foo.txt")->dirname; # "/tmp/"

Returns the directory portion you would get from calling
C<< File::Spec->splitpath( $path->stringify ) >> or C<"."> for a path without a
parent directory portion.  Because L<File::Spec> is inconsistent, the result
might or might not have a trailing slash.  Because of this, this method is
B<deprecated>.

A better, more consistently approach is likely C<< $path->parent->stringify >>,
which will not have a trailing slash except for a root directory.

=head2 exists, is_file, is_dir

    if ( path("/tmp")->exists ) { ... }     # -e
    if ( path("/tmp")->is_dir ) { ... }     # -d
    if ( path("/tmp")->is_file ) { ... }    # -e && ! -d

Implements file test operations, this means the file or directory actually has
to exist on the filesystem.  Until then, it's just a path.

B<Note>: C<is_file> is not C<-f> because C<-f> is not the opposite of C<-d>.
C<-f> means "plain file", excluding symlinks, devices, etc. that often can be
read just like files.

Use C<-f> instead if you really mean to check for a plain file.

=head2 filehandle

    $fh = path("/tmp/foo.txt")->filehandle($mode, $binmode);
    $fh = path("/tmp/foo.txt")->filehandle({ locked => 1 }, $mode, $binmode);

Returns an open file handle.  The C<$mode> argument must be a Perl-style
read/write mode string ("<" ,">", "<<", etc.).  If a C<$binmode>
is given, it is set during the C<open> call.

An optional hash reference may be used to pass options.  The only option is
C<locked>.  If true, handles opened for writing, appending or read-write are
locked with C<LOCK_EX>; otherwise, they are locked with C<LOCK_SH>.  When using
C<locked>, ">" or "+>" modes will delay truncation until after the lock is
acquired.

See C<openr>, C<openw>, C<openrw>, and C<opena> for sugar.

=head2 is_absolute, is_relative

    if ( path("/tmp")->is_absolute ) { ... }
    if ( path("/tmp")->is_relative ) { ... }

Booleans for whether the path appears absolute or relative.

=head2 is_rootdir

    while ( ! $path->is_rootdir ) {
        $path = $path->parent;
        ...
    }

Boolean for whether the path is the root directory of the volume.  I.e. the
C<dirname> is C<q[/]> and the C<basename> is C<q[]>.

This works even on C<MSWin32> with drives and UNC volumes:

    path("C:/")->is_rootdir;             # true
    path("//server/share/")->is_rootdir; #true

=head2 iterator

    $iter = path("/tmp")->iterator( \%options );

Returns a code reference that walks a directory lazily.  Each invocation
returns a C<Path::Tiny> object or undef when the iterator is exhausted.

    $iter = path("/tmp")->iterator;
    while ( $path = $iter->() ) {
        ...
    }

The current and parent directory entries ("." and "..") will not
be included.

If the C<recurse> option is true, the iterator will walk the directory
recursively, breadth-first.  If the C<follow_symlinks> option is also true,
directory links will be followed recursively.  There is no protection against
loops when following links. If a directory is not readable, it will not be
followed.

The default is the same as:

    $iter = path("/tmp")->iterator( {
        recurse         => 0,
        follow_symlinks => 0,
    } );

For a more powerful, recursive iterator with built-in loop avoidance, see
L<Path::Iterator::Rule>.

=head2 lines, lines_raw, lines_utf8

    @contents = path("/tmp/foo.txt")->lines;
    @contents = path("/tmp/foo.txt")->lines(\%options);
    @contents = path("/tmp/foo.txt")->lines_raw;
    @contents = path("/tmp/foo.txt")->lines_utf8;

    @contents = path("/tmp/foo.txt")->lines( { chomp => 1, count => 4 } );

Returns a list of lines from a file.  Optionally takes a hash-reference of
options.  Valid options are C<binmode>, C<count> and C<chomp>.  If C<binmode>
is provided, it will be set on the handle prior to reading.  If C<count> is
provided, up to that many lines will be returned. If C<chomp> is set, any
end-of-line character sequences (C<CR>, C<CRLF>, or C<LF>) will be removed
from the lines returned.

Because the return is a list, C<lines> in scalar context will return the number
of lines (and throw away the data).

    $number_of_lines = path("/tmp/foo.txt")->lines;

C<lines_raw> is like C<lines> with a C<binmode> of C<:raw>.  We use C<:raw>
instead of C<:unix> so PerlIO buffering can manage reading by line.

C<lines_utf8> is like C<lines> with a C<binmode> of
C<:raw:encoding(UTF-8)>.  If L<Unicode::UTF8> 0.58+ is installed, a raw
UTF-8 slurp will be done and then the lines will be split.  This is
actually faster than relying on C<:encoding(UTF-8)>, though a bit memory
intensive.  If memory use is a concern, consider C<openr_utf8> and
iterating directly on the handle.

=head2 mkpath

    path("foo/bar/baz")->mkpath;
    path("foo/bar/baz")->mkpath( \%options );

Like calling C<make_path> from L<File::Path>.  An optional hash reference
is passed through to C<make_path>.  Errors will be trapped and an exception
thrown.  Returns the list of directories created or an empty list if
the directories already exist, just like C<make_path>.

=head2 move

    path("foo.txt")->move("bar.txt");

Just like C<rename>.

=head2 openr, openw, openrw, opena

    $fh = path("foo.txt")->openr($binmode);  # read
    $fh = path("foo.txt")->openr_raw;
    $fh = path("foo.txt")->openr_utf8;

    $fh = path("foo.txt")->openw($binmode);  # write
    $fh = path("foo.txt")->openw_raw;
    $fh = path("foo.txt")->openw_utf8;

    $fh = path("foo.txt")->opena($binmode);  # append
    $fh = path("foo.txt")->opena_raw;
    $fh = path("foo.txt")->opena_utf8;

    $fh = path("foo.txt")->openrw($binmode); # read/write
    $fh = path("foo.txt")->openrw_raw;
    $fh = path("foo.txt")->openrw_utf8;

Returns a file handle opened in the specified mode.  The C<openr> style methods
take a single C<binmode> argument.  All of the C<open*> methods have
C<open*_raw> and C<open*_utf8> equivalents that use C<:raw> and
C<:raw:encoding(UTF-8)>, respectively.

An optional hash reference may be used to pass options.  The only option is
C<locked>.  If true, handles opened for writing, appending or read-write are
locked with C<LOCK_EX>; otherwise, they are locked for C<LOCK_SH>.

    $fh = path("foo.txt")->openrw_utf8( { locked => 1 } );

See L</filehandle> for more on locking.

=head2 parent

    $parent = path("foo/bar/baz")->parent; # foo/bar
    $parent = path("foo/wibble.txt")->parent; # foo

    $parent = path("foo/bar/baz")->parent(2); # foo

Returns a C<Path::Tiny> object corresponding to the parent directory of the
original directory or file. An optional positive integer argument is the number
of parent directories upwards to return.  C<parent> by itself is equivalent to
C<parent(1)>.

=head2 realpath

    $real = path("/baz/foo/../bar")->realpath;
    $real = path("foo/../bar")->realpath;

Returns a new C<Path::Tiny> object with all symbolic links and upward directory
parts resolved using L<Cwd>'s C<realpath>.  Compared to C<absolute>, this is
more expensive as it must actually consult the filesystem.

If the path can't be resolved (e.g. if it includes directories that don't exist),
an exception will be thrown:

    $real = path("doesnt_exist/foo")->realpath; # dies

=head2 relative

    $rel = path("/tmp/foo/bar")->relative("/tmp"); # foo/bar

Returns a C<Path::Tiny> object with a relative path name.
Given the trickiness of this, it's a thin wrapper around
C<< File::Spec->abs2rel() >>.

=head2 remove

    path("foo.txt")->remove;

B<Note: as of 0.012, remove only works on files>.

This is just like C<unlink>, except for its error handling: if the path does
not exist, it returns false; if deleting the file fails, it throws an
exception.

=head2 remove_tree

    # directory
    path("foo/bar/baz")->remove_tree;
    path("foo/bar/baz")->remove_tree( \%options );
    path("foo/bar/baz")->remove_tree( { safe => 0 } ); # force remove

Like calling C<remove_tree> from L<File::Path>, but defaults to C<safe> mode.
An optional hash reference is passed through to C<remove_tree>.  Errors will be
trapped and an exception thrown.  Returns the number of directories deleted,
just like C<remove_tree>.

If you want to remove a directory only if it is empty, use the built-in
C<rmdir> function instead.

    rmdir path("foo/bar/baz/");

=head2 slurp, slurp_raw, slurp_utf8

    $data = path("foo.txt")->slurp;
    $data = path("foo.txt")->slurp( {binmode => ":raw"} );
    $data = path("foo.txt")->slurp_raw;
    $data = path("foo.txt")->slurp_utf8;

Reads file contents into a scalar.  Takes an optional hash reference may be
used to pass options.  The only option is C<binmode>, which is passed to
C<binmode()> on the handle used for reading.

C<slurp_raw> is like C<slurp> with a C<binmode> of C<:unix> for
a fast, unbuffered, raw read.

C<slurp_utf8> is like C<slurp> with a C<binmode> of
C<:unix:encoding(UTF-8)>.  If L<Unicode::UTF8> 0.58+ is installed, a raw
slurp will be done instead and the result decoded with C<Unicode::UTF8>.
This is just as strict and is roughly an order of magnitude faster than
using C<:encoding(UTF-8)>.

=head2 spew, spew_raw, spew_utf8

    path("foo.txt")->spew(@data);
    path("foo.txt")->spew(\@data);
    path("foo.txt")->spew({binmode => ":raw"}, @data);
    path("foo.txt")->spew_raw(@data);
    path("foo.txt")->spew_utf8(@data);

Writes data to a file atomically.  The file is written to a temporary file in
the same directory, then renamed over the original.  An optional hash reference
may be used to pass options.  The only option is C<binmode>, which is passed to
C<binmode()> on the handle used for writing.

C<spew_raw> is like C<spew> with a C<binmode> of C<:unix> for a fast,
unbuffered, raw write.

C<spew_utf8> is like C<spew> with a C<binmode> of C<:unix:encoding(UTF-8)>.
If L<Unicode::UTF8> 0.58+ is installed, a raw spew will be done instead on
the data encoded with C<Unicode::UTF8>.

=head2 stat, lstat

    $stat = path("foo.txt")->stat;
    $stat = path("/some/symlink")->lstat;

Like calling C<stat> or C<lstat> from L<File::stat>.

=head2 stringify

    $path = path("foo.txt");
    say $path->stringify; # same as "$path"

Returns a string representation of the path.  Unlike C<canonpath>, this method
returns the path standardized with Unix-style C</> directory separators.

=head2 subsumes

    path("foo/bar")->subsumes("foo/bar/baz"); # true
    path("/foo/bar")->subsumes("/foo/baz");   # false

Returns true if the first path is a prefix of the second path at a directory
boundary.

This B<does not> resolve parent directory entries (C<..>) or symlinks:

    path("foo/bar")->subsumes("foo/bar/../baz"); # true

If such things are important to you, ensure that both paths are resolved to
the filesystem with C<realpath>:

    my $p1 = path("foo/bar")->realpath;
    my $p2 = path("foo/bar/../baz")->realpath;
    if ( $p1->subsumes($p2) ) { ... }

=head2 touch

    path("foo.txt")->touch;
    path("foo.txt")->touch($epoch_secs);

Like the Unix C<touch> utility.  Creates the file if it doesn't exist, or else
changes the modification and access times to the current time.  If the first
argument is the epoch seconds then it will be used.

Returns the path object so it can be easily chained with spew:

    path("foo.txt")->touch->spew( $content );

=head2 touchpath

    path("bar/baz/foo.txt")->touchpath;

Combines C<mkpath> and C<touch>.  Creates the parent directory if it doesn't exist,
before touching the file.  Returns the path object like C<touch> does.

=head2 volume

    $vol = path("/tmp/foo.txt")->volume;   # ""
    $vol = path("C:/tmp/foo.txt")->volume; # "C:"

Returns the volume portion of the path.  This is equivalent
equivalent to what L<File::Spec> would give from C<splitpath> and thus
usually is the empty string on Unix-like operating systems or the
drive letter for an absolute path on C<MSWin32>.

=for Pod::Coverage openr_utf8 opena_utf8 openw_utf8 openrw_utf8
openr_raw opena_raw openw_raw openrw_raw
IS_BSD IS_WIN32 FREEZE THAW TO_JSON

=head1 EXCEPTION HANDLING

Simple usage errors will generally croak.  Failures of underlying Perl
unctions will be thrown as exceptions in the class
C<Path::Tiny::Error>.

A C<Path::Tiny::Error> object will be a hash reference with the following fields:

=over 4

=item *

C<op> — a description of the operation, usually function call and any extra info

=item *

C<file> — the file or directory relating to the error

=item *

C<err> — hold C<$!> at the time the error was thrown

=item *

C<msg> — a string combining the above data and a Carp-like short stack trace

=back

Exception objects will stringify as the C<msg> field.

=head1 CAVEATS

=head2 File locking

If flock is not supported on a platform, it will not be used, even if
locking is requested.

See additional caveats below.

=head3 NFS and BSD

On BSD, Perl's flock implementation may not work to lock files on an
NFS filesystem.  Path::Tiny has some heuristics to detect this
and will warn once and let you continue in an unsafe mode.  If you
want this failure to be fatal, you can fatalize the 'flock' warnings
category:

    use warnings FATAL => 'flock';

=head3 AIX and locking

AIX requires a write handle for locking.  Therefore, calls that normally
open a read handle and take a shared lock instead will open a read-write
handle and take an exclusive lock.  If the user does not have write
permission, no lock will be used.

=head2 utf8 vs UTF-8

All the C<*_utf8> methods use C<:encoding(UTF-8)> -- either as
C<:unix:encoding(UTF-8)> (unbuffered) or C<:raw:encoding(UTF-8)> (buffered) --
which is strict against the Unicode spec and disallows illegal Unicode
codepoints or UTF-8 sequences.

Unfortunately, C<:encoding(UTF-8)> is very, very slow.  If you install
L<Unicode::UTF8> 0.58 or later, that module will be used by some C<*_utf8>
methods to encode or decode data after a raw, binary input/output operation,
which is much faster.

If you need the performance and can accept the security risk,
C<< slurp({binmode => ":unix:utf8"}) >> will be faster than C<:unix:encoding(UTF-8)>
(but not as fast as C<Unicode::UTF8>).

Note that the C<*_utf8> methods read in B<raw> mode.  There is no CRLF
translation on Windows.  If you must have CRLF translation, use the regular
input/output methods with an appropriate binmode:

  $path->spew_utf8($data);                            # raw
  $path->spew({binmode => ":encoding(UTF-8)"}, $data; # LF -> CRLF

Consider L<PerlIO::utf8_strict> for a faster L<PerlIO> layer alternative to
C<:encoding(UTF-8)>, though it does not appear to be as fast as the
C<Unicode::UTF8> approach.

=head2 Default IO layers and the open pragma

If you have Perl 5.10 or later, file input/output methods (C<slurp>, C<spew>,
etc.) and high-level handle opening methods ( C<filehandle>, C<openr>,
C<openw>, etc. ) respect default encodings set by the C<-C> switch or lexical
L<open> settings of the caller.  For UTF-8, this is almost certainly slower
than using the dedicated C<_utf8> methods if you have L<Unicode::UTF8>.

=head1 TYPE CONSTRAINTS AND COERCION

A standard L<MooseX::Types> library is available at
L<MooseX::Types::Path::Tiny>.  A L<Type::Tiny> equivalent is available as
L<Types::Path::Tiny>.

=head1 SEE ALSO

These are other file/path utilities, which may offer a different feature
set than C<Path::Tiny>.

=over 4

=item *

L<File::chmod>

=item *

L<File::Fu>

=item *

L<IO::All>

=item *

L<Path::Class>

=back

These iterators may be slightly faster than the recursive iterator in
C<Path::Tiny>:

=over 4

=item *

L<Path::Iterator::Rule>

=item *

L<File::Next>

=back

There are probably comparable, non-Tiny tools.  Let me know if you want me to
add a module to the list.

This module was featured in the L<2013 Perl Advent Calendar|http://www.perladvent.org/2013/2013-12-18.html>.

=for :stopwords cpan testmatrix url annocpan anno bugtracker rt cpants kwalitee diff irc mailto metadata placeholders metacpan

=head1 SUPPORT

=head2 Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at L<https://github.com/dagolden/Path-Tiny/issues>.
You will be notified automatically of any progress on your issue.

=head2 Source Code

This is open source software.  The code repository is available for
public review and contribution under the terms of the license.

L<https://github.com/dagolden/Path-Tiny>

  git clone https://github.com/dagolden/Path-Tiny.git

=head1 AUTHOR

David Golden <dagolden@cpan.org>

=head1 CONTRIBUTORS

=for stopwords Chris Williams Michael G. Schwern Smylers Toby Inkster 김도형 - Keedi Kim David Steinbrunner Doug Bell Gabor Szabo Gabriel Andrade George Hartzell Geraud Continsouzas Goro Fuji Karen Etheridge Martin Kjeldsen

=over 4

=item *

Chris Williams <bingos@cpan.org>

=item *

Michael G. Schwern <mschwern@cpan.org>

=item *

Smylers <Smylers@stripey.com>

=item *

Toby Inkster <tobyink@cpan.org>

=item *

김도형 - Keedi Kim <keedi@cpan.org>

=item *

David Steinbrunner <dsteinbrunner@pobox.com>

=item *

Doug Bell <madcityzen@gmail.com>

=item *

Gabor Szabo <szabgab@cpan.org>

=item *

Gabriel Andrade <gabiruh@gmail.com>

=item *

George Hartzell <hartzell@cpan.org>

=item *

Geraud Continsouzas <geraud@scsi.nc>

=item *

Goro Fuji <gfuji@cpan.org>

=item *

Karen Etheridge <ether@cpan.org>

=item *

Martin Kjeldsen <mk@bluepipe.dk>

=back

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by David Golden.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004

=cut
