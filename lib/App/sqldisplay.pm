package App::sqldisplay 0.01;
use 5.020;
use experimental 'signatures';
use Scalar::Util 'weaken';
use Carp 'croak';
use YAML 'LoadFile';

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

1;
