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

use Try::Tiny;
use PerlX::Maybe;
use Encode 'decode';
use Mojo::URL;
use Mojo::File;

use App::sqldisplay;

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

sub add_client( $client ) {
    # It seems that we need some kind of PING / PONG here
    state $heartbeat = Mojo::IOLoop->timer( 5 => sub($t) {
        for my $c (values %clients) {
            use Mojo::WebSocket qw(WS_PING);
            local $| = 1;
            print "\rPING\r";
            $client->send([1, 0, 0, 0, WS_PING, '']);
        };
    });
    $client = $client->inactivity_timeout(3600);

    my $id = $last_id++;
    my $clients = \%clients;
    $clients->{ $id } = $client->tx;
    $client->inactivity_timeout(60);
    $client->on(finish => sub( $c, @rest ) {
        say "Client $id went away";
        delete $clients->{ $id };
    });
    say "Added client $id as WS client";
    $id;
}

sub notify_client( $client_id, @actions ) {
    say "Notifying $client_id";
    my $client = $clients{ $client_id };
    for my $action (@actions) {
        # Convert path to what the client will likely have requested (duh)

        # These rules should all come from a config file, I guess
        #app->log->info("Notifying client $client_id of '$action->{name}' change to '$action->{path}'");
        #use Data::Dumper; warn Dumper $action;
        #$client->send({json => $action });
        $client->send($action);
    };
}

sub notify_clients( @actions ) {
    my $clients = \%clients;
    for my $client_id (sort keys %$clients ) {
        notify_client( $client_id, @actions );
    };
}

sub run_query( $dbh, $query ) {
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
        warn "'$query->{title}': $_";
    };
    return {
              title => $query->{title},
            headers => $cols,
               rows => $rows,
        maybe error => $error,
    }
}

my $app = App::sqldisplay->new(
    spreadsheet_file => $spreadsheet_file,
    config_file => $query_file,
);

sub file_changed( $self, $ev ) {
    say "Modified: $ev->{path}";
    my $dirty;
    if( $ev->path eq $spreadsheet_file ) {
        # reload the DB
        say "Reloading spreadsheet";
        reload_sheet( $spreadsheet_file );
        $dirty = 1;
    } elsif( $ev->path eq $query_file ) {
        # reload the queries
        say "Reloading queries";
        $app->load_config( $query_file );
        $dirty = 1;
    }

    if( $dirty ) {
        # (Re)render the tables
        my @results = run_queries( $app->queries->@* );
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

sub run_queries(@queries) {
    my $dbh = $app->sheet->dbh;

    map { run_query( $dbh, $_ ) } $app->queries->@*
}

$app->load_config();
$app->load_sheet();

websocket '/notify' => sub($c) {
    my $client_id = add_client( $c );
    if(! $app->url_base ) {
        $app->url_base( $c->req->url->clone->to_abs );
    };
    # Just in case an old client reconnects
    # Maybe that client could tell us ...
    #notify_client( $client_id, { type => 'reload' });
};

sub get_tabs( $active ) {
    [map { { name => $_->{name}, active => $_->{name} eq $active } } $app->config->{tabs}->@*]
}

get '/index' => sub( $c ) {
    # rerun all queries
    if( ! $app->url_base ) {
        $app->url_base( $c->req->url->clone->to_abs );
    }
    my $name = $c->param('tab');
    my ($active) = grep { $name eq $_->{name} } $app->config->{tabs}->@*;
    $active //= $app->config->{tabs}->[0];

    my %queries = map {
        $_->{title} => $_;
    } $app->queries->@*;

    my @results = run_queries( map { $queries{ $_ } } $active->{queries}->@* );
    my $tabs = get_tabs( $active->{name} );
    $c->stash( tabs => $tabs );
    $c->stash( results => \@results );
};

get '/query/:name' => sub( $c ) {
    # Get results for one specific query
    if(! $app->url_base ) {
        $app->url_base( $c->req->url->clone->to_abs );
    };
    my $q = $c->param('name');

    (my $query) = grep { $_->{title} eq $q } $app->queries->@*;
    my @results = run_queries( $query );
    $c->stash( res => $results[0] );
    $c->render( 'query' );
};

# Serve a static document from the "documents" directory
get '/doc/*document' => sub( $c ) {
    my $fn = $c->param('document');
    $fn =~ s!\.\.+!!g;
    if( ! Mojo::File->new( $app->config->{documents} )->is_abs ) {
        $app->config->{documents} = dirname($query_file) . '/' . $app->config->{documents};
    }
    my $target = join "/", $app->config->{documents}, $fn;
    $c->reply->file( $target );
};


app->start;
#Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
__DATA__
@@index.html.ep
<!DOCTYPE html>
<html>
<head>
<script src="htmx.1.9.12.js"></script>
<!--
//            if (type == 'reload') location.reload()
//            if (type == 'jsInject') eval(str)
//            if (type == 'refetch') {
-->
<script src="ws.1.9.12.js"></script>
<script src="idiomorph-ext.0.3.0.js"></script>
<style>
body { margin: 0px; }

.container {
  display: flex;
  flex-flow: column;
  align-items: stretch;
  height: 100vh;
  background: #eee;
}

.ui-top {
  height: 100px;
  width: 100px; /* A fixed width as the default */
}

.ui-main {
  flex: 1;
  /* flex-grow: 1; /* Set the middle element to grow and stretch */
  overflow: auto;
  background: #ddd;

  display: flex;
  flex-flow: row;
  align-items: stretch;
}

.ui-main-left {
  width: 50%;
  overflow: auto;
  background: #ccc;
}

.ui-main-right {
  width: 50%;
  overflow: auto;
  background: #bbb;
}

.ui-bottom {
  min-height: 32px;
  padding: 0px;
  margin: 0px;
}

.tabs {
    display: flex;
    flex-wrap: wrap;
    flex-direction: column;
    gap: 4px;
}

.tabs > ol {
  display: inline;
  /* background: #aaa; */
  padding-top: 8px;
  margin: 0px;
}

.tabs > ol > li {
  width: 100%;
  padding-top: 8px;
  padding-left: 1em;
  padding-right: 1em;
  cursor: pointer;
  display: inline;
  border: solid 0.1rem black;
  margin: 0px;
}

.tabs li.active {
    font-weight: bold;
  border-top: none;
  background: #ccc;
}

td.num { text-align: right };

thead {
    position: sticky;
    top: 0;
}

tr:nth-child(odd) {
    background-color: #DDD;
}
</style>
</head>
<body hx-ext="ws" ws-connect="/notify">
    <div id="container" class="container">
        <div id="main_content" class="ui-main">
            <!--<div id="row" class="ui-main-left"> -->
            <div class="ui-main-left" style="overflow: auto;">
% for my $res (@$results) {
%= include 'query', res => $res;
% }
            </div>
            <iframe name="detail" class="ui-main-right"></iframe>
        </div>
        <div class="ui-bottom">
%= include 'tabs';
        </div>
    </div>
</body>
</html>

@@tabs.html.ep
<div class="tabs">
    <ol id="ui-tabs">
% for my $t ($tabs->@*) {
        <li class="<%= $t->{active} ? "active" : "" %>">
            <a href="?tab=<%= $t->{name} %>"><%= $t->{name} %></a>
        </li>
% }
    </ol>
</div>

@@query.html.ep
<div id="table-<%= $res->{title} %>">
<h1><%= $res->{title} %></h1>
<table>
<thead>
<tr>
% for my $h (@{ $res->{headers}}) {
    <th><%= $h->{name} %></th>
% }
</tr>
</thead>
<tbody>
% for my $r (@{ $res->{rows}}) {
    <tr>
    % for my $c (@{ $res->{headers}}) {
        % my $class = $c->{type} // '';
        % my $urlify = $c->{name} =~ m!\burl\s*\(!;
        % if( $urlify ) {
        <td class="<%= $class %>"><a href="<%= $r->{ $c->{name} } %>" target="detail"><%= $r->{ $c->{name} } %></a></td>
        % } else {
        <td class="<%= $class %>"><%= $r->{ $c->{name} } %></td>
        % }
    % }
    </tr>
% }
</tbody>
</table>
</div>
