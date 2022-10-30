#!perl
use strict;
use warnings;

use Mojolicious::Lite;
use File::Basename 'dirname';

use DBIx::Spreadsheet;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

use Try::Tiny;
use PerlX::Maybe;
use YAML 'LoadFile';
use Encode 'decode', 'encode';
use Text::Table;

# Should we read the spreadsheet from the queries file?!
# At least optionally?

use File::ChangeNotify;
use File::ChangeNotify::Event;

sub instantiate_watcher(%options) {
    my $on_change = delete $options{ on_change };

    my $watcher = File::ChangeNotify->instantiate_watcher( %options );
    while( my @events = $watcher->wait_for_events()) {
        #warn sprintf "Child got '%s'", $events[0]->type;

        for my $ev ( @events ) {
            $on_change->( $ev );
        };
    };
};

use Getopt::Long ':config', 'pass_through';
GetOptions(
    'f|spreadsheet=s' => \my $spreadsheet_file,
    'q|query=s' => \my $query_file,
);

$spreadsheet_file //= '/home/corion/Dokumente/Frankfurt Perlmongers e.V/Buchhaltung/Buchhaltung 2021/2021 Rechnungen.ods';
$query_file       //= dirname($spreadsheet_file) . '/dashboard.yml';

sub file_changed( $ev ) {
    if( $ev->path eq $spreadsheet_file ) {
        # reload the DB
        say "Reloading spreadsheet";
        reload_sheet( $spreadsheet_file );
    } elsif( $ev->path eq $query_file ) {
        # reload the queries
        say "Reloading queries";
        reload_queries( $query_file );
    }

    # Rerun and re-output queries
    rerun_queries();
}


sub run_query( $dbh, $query ) {
    my ($sth,$cols,$types,$rows,$error);
    try {
        my $sth = $dbh->prepare( $query->{sql} );
        $sth->execute();
        $rows = $sth->fetchall_arrayref( {} );
        $cols = [ map { +{ name => decode('UTF-8', $_), type => $rows->[0]->{$_} =~ /^[+-]?\d/ ? 'num' : undef } } @{ $sth->{NAME} }];

        for my $r (@$rows) {
            for (values %$r) {
                $_ = decode('UTF-8', $_);
            };
        };
    } catch {
        $error = $_;
        warn $_;
    };
    return {
              title => $query->{title},
            headers => $cols,
               rows => $rows,
        maybe error => $error,
    }
}

my @queries;
my $sheet;

sub run_queries(@queries) {
    my $dbh = $sheet->dbh;

    map { run_query( $dbh, $_ ) } @queries
}

sub reload_queries( $file ) {
    @queries = grep { $_->{title} or $_->{sql} } LoadFile($file);
}

sub reload_sheet( $file ) {
    $sheet = DBIx::Spreadsheet->new( file => $file )
        or die "Couldn't read '$file'";
}

sub rerun_queries {
    my @results = run_queries( @queries );

    system('clear');

    for my $r (@results) {
        say $r->{title};

        my @cols = map { $_->{name} } @{ $r->{headers}};

        if( $r->{error} ) {
            say $r->{name};
            say $r->{error};

        } else {
            my $t = Text::Table->new(map { +{ title => $_->{name}, align => ($_->{type} || '') eq 'numeric' ? 'r' : 'l' } } @{ $r->{headers}});
            $t->load( map { [ @{$_}{@cols} ]} @{ $r->{rows}} );

            say $t;
        }
    };
}

binmode STDOUT, ':encoding(UTF-8)';

reload_queries( $query_file );
reload_sheet( $spreadsheet_file );
rerun_queries();
instantiate_watcher(
# Add the spreadsheet here
# Add the query file here
# Add the html template here
# Maybe even add an SQLite file here?!
    directories => [dirname $spreadsheet_file, dirname $query_file],
    on_change => \&file_changed,
);
