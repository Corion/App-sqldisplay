package App::sqldisplay 0.01;
use 5.020;
use experimental 'signatures';
use Try::Tiny;
use PerlX::Maybe;
use Scalar::Util 'weaken';
use Carp 'croak';
use YAML 'LoadFile';
use Encode 'decode';

use Moo 2;

has 'config_file' => (
    is => 'ro',
    required => 1,
);

has 'spreadsheet_file' => (
    is => 'ro',
    required => 1,
);

has 'config' => (
    is => 'rw',
    default => sub { {} },
);

has 'queries' => (
    is => 'rw',
    default => sub { [] },
);

has 'sheet' => (
    is => 'rw',
);

has 'url_base' => (
    is => 'rw',
);

sub documents( $self ) {
    $self->config->{documents}
}

sub load_config( $self, $file = $self->config_file ) {
    my ($config, @queries) = LoadFile($file);
    $self->config( $config );
    $self->queries( \@queries );
    return $self
}

sub load_sheet( $self, $file = $self->spreadsheet_file ) {
    my $sheet = DBIx::Spreadsheet->new( file => $file )
        or croak "Couldn't read '$file'";
    weaken( my $s = $self);
    my $base;
    $sheet->dbh->sqlite_create_function('url', -1, sub($url, $base=undef) {
        if( defined $url ) {
            $base //= Mojo::URL->new( $s->url_base->clone );
            return Mojo::URL->new($url)->base($base)->to_abs
        } else {
            return undef
        };
    });
    $self->sheet( $sheet );
    return $sheet
}

sub run_query( $self, $dbh, $query ) {
    my ($sth,$cols,$types,$rows,$error);
    try {
        my $sth = $dbh->prepare( $query->{sql} );
        $sth->execute();
        $rows = $sth->fetchall_arrayref( {} );
        $cols = [ map { +{ name => decode('UTF-8', $_), type => ($rows->[0]->{$_} // '') =~ /^[+-]?\d/ ? 'num' : undef } } @{ $sth->{NAME} }];

        for my $r (@$rows) {
            for (values %$r) {
                $_ = decode('UTF-8', $_);
            };
        };
    } catch {
        $error = $_;
    };
    return {
              title => $query->{title},
            headers => $cols,
               rows => $rows,
        maybe error => $error,
    }
}

1;
