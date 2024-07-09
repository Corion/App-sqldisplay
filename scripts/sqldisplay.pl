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

use App::sqldisplay;

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

my $app = App::sqldisplay->new(
    spreadsheet_file => $spreadsheet_file,
    config_file => $query_file,
);

sub file_changed( $ev ) {
    my $dirty;
    if( $ev->path eq $spreadsheet_file ) {
        # reload the DB
        say "Reloading spreadsheet";
        $app->load_sheet();
        $dirty = 1;
    } elsif( $ev->path eq $query_file ) {
        # reload the queries
        say "Reloading queries";
        $app->load_config();
        $dirty = 1;
    }

    if( $dirty ) {

        # Rerun and re-output queries
        rerun_queries();
    }
}

sub rerun_queries {
    my @results = $app->run_queries($app->queries->@*);

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

$app->load_config();
$app->load_sheet();
rerun_queries();
instantiate_watcher(
# Add the spreadsheet here
# Add the query file here
# Add the html template here
# Maybe even add an SQLite file here?!
    directories => [dirname $spreadsheet_file, dirname $query_file],
    on_change => \&file_changed,
);
