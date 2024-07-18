#!perl
use strict;
use warnings;

use Mojolicious::Lite;
use File::Basename 'dirname';

use lib 'lib';
use lib '../DBIx-Spreadsheet/lib';
use DBIx::Spreadsheet;

use 5.020; # for signatures
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::URL;
use Mojo::File;

use App::sqldisplay;

# CamelCase plugin name
package Mojolicious::Plugin::CleanFragment {
use 5.020;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Text::CleanFragment;

sub register ($self, $app, $conf) {
    $app->helper('clean_fragment' => sub($self,@args) { clean_fragment(@args)} );
}
}

  # M

#use MojoX::ChangeNotify;

# Should we read the spreadsheet from the queries file?!
# At least optionally?

package MojoX::ChangeNotify {
    use strict;
    use warnings;

    use File::ChangeNotify;
    use File::ChangeNotify::Event;
    use Mojo::IOLoop::Subprocess;
    use Mojo::Base 'Mojo::EventEmitter';

    use 5.020; # for signatures
    use feature 'signatures';
    no warnings 'experimental::signatures';

    has 'child';

    sub instantiate_watcher($self, %options) {
        my $subprocess = Mojo::IOLoop::Subprocess->new();
        $self->child( $subprocess );

        $subprocess->on('progress' => sub( $subprocess, @events ) {
            # Emit "changed" events

            for my $ev (@events) {
                delete $ev->{attributes} unless $ev->{has_attributes};
                delete $ev->{content} unless $ev->{has_content};

                $self->emit( $ev->{type}, File::ChangeNotify::Event->new( $ev ));
            };
        });

        # Operation that would block the event loop for 5 seconds (with promise)
        $subprocess->run_p(sub($subprocess) {
            my $watcher = File::ChangeNotify->instantiate_watcher( %options );
            while( my @events = $watcher->wait_for_events()) {
                #warn sprintf "Child got '%s'", $events[0]->type;

                @events = map {
                    +{ type           => $_->type,
                       path           => $_->path,
                       attributes     => $_->attributes,
                       has_attributes => $_->has_attributes,
                       content        => $_->content,
                       has_content    => $_->has_content,
                    },
                } @events;

                $subprocess->progress( @events );
            };
        })->catch(sub  {
            my $err = shift;
            say "Subprocess error: $err";
        });
    };

    # emits "changed"

};

use Getopt::Long ':config', 'pass_through';
GetOptions(
    'f|spreadsheet=s' => \my $spreadsheet_file,
    'q|query=s' => \my $query_file,
    'y|year=s' => \my $year,
);

$year //= (localtime)[5] + 1900;

my $watcher = MojoX::ChangeNotify->new();
$spreadsheet_file //= "/home/corion/Dokumente/Frankfurt Perlmongers e.V/Buchhaltung/Buchhaltung $year/$year Rechnungen.ods";
$query_file       //= dirname($spreadsheet_file) . '/dashboard.yml';

$watcher->instantiate_watcher(
# Add the spreadsheet here
# Add the query file here
# Add the html template here
# Maybe even add an SQLite file here?!
    directories => [dirname $spreadsheet_file, dirname $query_file],
);

my $last_id = 1;
my %clients;

app->plugin('CleanFragment');

sub add_client( $client ) {
    # It seems that we need some kind of PING / PONG here
    state $heartbeat = Mojo::IOLoop->timer( 10 => sub($t) {
        for my $c (values %clients) {
            use Mojo::WebSocket qw(WS_PING);
            local $| = 1;
            #print "\rPING\r";
            $client->send([1, 0, 0, 0, WS_PING, '']);
        };
    });
    $client = $client->inactivity_timeout(3600);

    my $id = $last_id++;
    my $clients = \%clients;
    $clients->{ $id } = $client->tx;
    $client->on(finish => sub( $c, @rest ) {
        say "Client $id went away";
        delete $clients->{ $id };
    });

    $client->on('json' => sub ($c, $msg) {
        use Data::Dumper;
        warn "Client message: " . Dumper $msg;
    });

    #say "Added client $id as WS client";
    $id;
}

sub notify_client( $client_id, @actions ) {
    say "Notifying $client_id";
    my $client = $clients{ $client_id };
    for my $action (@actions) {
        $client->send($action);
    };
}

sub notify_clients( @actions ) {
    my $clients = \%clients;
    for my $client_id (sort keys %$clients ) {
        notify_client( $client_id, @actions );
    };
}

my $app = App::sqldisplay->new(
    spreadsheet_file => $spreadsheet_file,
    config_file => $query_file,
);

sub file_changed( $self, $ev ) {
    #say "Modified: $ev->{path}";
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
        # (Re)render the tables
        my @results = $app->run_queries( $app->queries->@* );
        my @html = map {

            my $tx = Mojo::Transaction::HTTP->new();
            $tx->req->method('GET');
            $tx->req->url->parse('https://example.com/query');
            my $c = Mojolicious::Controller->new( app => app(), tx => $tx );

            my $html = $c->render_to_string('query', res => $_);
            #warn $html;
            $html
        } @results;

        # Push a reload to the client(s)
        # Actually, we'd like to push the elements to reload/refresh, maybe?!
        notify_clients( @html );
    };
};
$watcher->on('create' => \&file_changed);
$watcher->on('modify' => \&file_changed);

$app->load_config();
$app->load_sheet();

sub fix_url_base( $c ) {
    if(! $app->url_base ) {
        warn "Fixing URL base to " . $c->req->url->clone->to_abs;
        $app->url_base( $c->req->url->clone->to_abs );
    };
}

websocket '/notify' => sub($c) {
    fix_url_base( $c );
    my $client_id = add_client( $c );

    # Just in case an old client reconnects
    # Maybe that client could tell us what version it has so we don't render
    # this page twice?! Also, what tab it has?!
    if( $c->param('version') != $$ ) {
        say "Updating client page";
        render_index($c);
        my $html = $c->render_to_string('index');
        notify_client( $client_id => $html );
    };
};

sub get_tabs( $active ) {
    [map { { name => $_->{name}, active => $_->{name} eq $active } } $app->tabs->@*]
}

sub render_index( $c ) {
    # rerun all queries
    fix_url_base( $c );
    my $name = $c->param('tab');
    my $active;
    if( defined $name ) {
        ($active) = grep { $name eq $_->{name} } $app->tabs->@*;
    };
    if( ! $active ) {
        $name //= '';
        say "No tab found for '$name' in " . join ", ", map { $_->{name} } $app->tabs->@*;
        $active = $app->tabs->[0];
        $name = $active->{name};
    };
    say "Rendering for '$name'";

    my @results = $app->run_queries( $app->queries_for_tab( $name ) );
    my $tabs = get_tabs( $active->{name} );
    $c->stash( tabs => $tabs );
    $c->stash( results => \@results );
};
get '/index' => \&render_index;
post '/index' => sub($c) {
    #for my $p ($c->req->params->names->@*) {
    #    say "$p -> " . $c->param($p);
    #}
    my @votes = grep { /^vote_/ } $c->req->params->names->@*;
    if( $c->req->headers->header('HX-Request')) {
        say "Returning just the vote field $votes[0] -> " . $c->param($votes[0]);
        $c->render( text => sprintf q{<div class="vote">%s</div>}, $c->param( $votes[0] ));
    } else {
        say "Returning the full page";
        return render_index($c);
    }
};

get '/query/:name' => sub( $c ) {
    # Get results for one specific query
    fix_url_base( $c );
    my $q = $c->param('name');

    (my $query) = grep { $_->{title} eq $q } $app->queries->@*;
    my @results = $app->run_queries( $query );
    $c->stash( res => $results[0] );
    $c->render( 'query' );
};

# Serve a static document from the "documents" directory
get '/doc/*document' => sub( $c ) {
    my $fn = $c->param('document');
    $fn =~ s!\.\.+!!g;

    my $target = join "/", $app->documents, $fn;
    $c->reply->file( $target );
};

app->start;
