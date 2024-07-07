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
use YAML 'LoadFile';
use Encode 'decode';
use Mojo::URL;
use Mojo::File;

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
        #})->then(sub (@results) {
        #    say "I $results[0] $results[1]!";
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
);

my $watcher = MojoX::ChangeNotify->new();
$spreadsheet_file //= '/home/corion/Dokumente/Frankfurt Perlmongers e.V/Buchhaltung/Buchhaltung 2022/2022 Rechnungen.ods';
$query_file       //= dirname($spreadsheet_file) . '/dashboard.yml';

$watcher->instantiate_watcher(
# Add the spreadsheet here
# Add the query file here
# Add the html template here
# Maybe even add an SQLite file here?!
    directories => [dirname $spreadsheet_file, dirname $query_file],
);

$watcher->on('modify' => sub ( $self, $ev ) {
    say "Modified: $ev->{path}";
    #if( $ev->path eq $spreadsheet_file ) {
        # reload the DB
        say "Reloading spreadsheet";
        reload_sheet( $spreadsheet_file );
    #} elsif( $ev->path eq $query_file ) {
        # reload the queries
        say "Reloading queries";
        reload_queries( $query_file );
    #}

    # Push a reload to the client(s)
    # Actually, we'd like to push the elements to reload/refresh, maybe?!
    notify_clients( {type => 'reload'} );
});

my $last_id = 1;
my %clients;

sub add_client( $client ) {
    my $id = $last_id++;
    my $clients = \%clients;
    $clients->{ $id } = $client->tx;
    $client->inactivity_timeout(60);
    $client->on(finish => sub( $c, @rest ) {
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
        use Data::Dumper; warn Dumper $action;
        $client->send({json => $action });
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

my @queries;
my $config;
my $sheet;

sub run_queries(@queries) {
    my $dbh = $sheet->dbh;

    map { run_query( $dbh, $_ ) } @queries
}

sub reload_queries( $file ) {
    ($config, @queries) = LoadFile($file);
}

our $server_base;
sub reload_sheet( $file ) {
    $sheet = DBIx::Spreadsheet->new( file => $file )
        or die "Couldn't read '$file'";
    $sheet->dbh->sqlite_create_function('url', -1, sub($url, $base=undef) {
        if( defined $url ) {
            $base //= $server_base->clone;
            $base = Mojo::URL->new( $base );
            return Mojo::URL->new($url)->base($base)->to_abs
        } else {
            return undef
        };
    });
}

reload_queries( $query_file );
reload_sheet( $spreadsheet_file );

websocket sub($c) {
    my $client_id = add_client( $c );
    $server_base //= $c->req->url->clone->to_abs;
    # Just in case an old client reconnects
    # Maybe that client could tell us ...
    #notify_client( $client_id, { type => 'reload' });
};

get '/index' => sub( $c ) {
    # rerun all queries
    $server_base //= $c->req->url->clone->to_abs;
    my @results = run_queries( @queries );
    $c->stash( results => \@results );
};

get '/query/:name' => sub( $c ) {
    # Get results for one specific query
    $server_base //= $c->req->url->clone->to_abs;
    my $q = $c->param('name');

    (my $query) = grep { $_->{title} eq $q } @queries;
    my @results = run_queries( $query );
    $c->stash( res => $results[0] );
    $c->render( 'query' );
};

# Serve a static document from the "documents" directory
get '/doc/*document' => sub( $c ) {
    my $fn = $c->param('document');
    $fn =~ s!\.\.+!!g;
    if( ! Mojo::File->new( $config->{documents} )->is_abs ) {
        $config->{documents} = dirname($query_file) . '/' . $config->{documents};
    }
    my $target = join "/", $config->{documents}, $fn;
    $c->reply->file( $target );
};


app->start;
#Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
__DATA__
@@index.html.ep
<!DOCTYPE html>
<html>
<head>
<!-- hot-server appends this snippit to inject code via a websocket  -->
<script>
function _ws_reopen() {
    //console.log("Retrying connection");
    var me = {
        retry: null,
        ping: null,
        was_connected: null,
        _ws: null,
        reconnect: () => {
            if( me.ping ) {
                clearInterval( me.ping );
                me.ping = null;
            };
            me._ws = null;
            if(!me.retry) {
                me.retry = setTimeout( () => { try { me.open(); } catch( e ) { console.log("Whoa" )} }, 5000 );
            };
        },
        open: () => {
            me.retry = null;
            me._ws = new WebSocket(location.origin.replace(/^http/, 'ws'));
            me._ws.addEventListener('close', (e) => {
                me.reconnect();
            });
            me._ws.addEventListener('error', (e) => {
                me.reconnect();
            });
            me._ws.addEventListener('open', () => {
                if( me.retry ) {
                    clearInterval(me.retry)
                    me.retry = null;
                };
                me.was_connected = true;
                if( !me.ping) {
                    me.ping = setInterval( () => {
                      try {
                          me._ws.send( "ping" )
                      } catch( e ) {
                          //console.log("Lost connection", e);
                          me._ws.onerror(e);
                      };
                    }, 5000 );
                };
            });
            me._ws.addEventListener('message', (msg) => {
            try {
              var {path, type, selector, attr, str} = JSON.parse(msg.data);
              console.log(msg.data);
            } catch(e) { console.log(e) };
            if (type == 'reload') location.reload()
            if (type == 'jsInject') eval(str)
            if (type == 'refetch') {
              try {
                  Array.from(document.querySelectorAll(selector))
                    .filter(d => d[attr].includes(path))
                    .forEach(function( d ) {
                        try {
                            const cacheBuster = '?dev=' + Math.floor(Math.random() * 100); // Justin Case, cache buster
                            d[attr] = d[attr].replace(/\?(?:dev=.*?(?=\&|$))|$/, cacheBuster);
                            console.log(d[attr]);
                        } catch( e ) {
                            console.log(e);
                        };
                    });
                    } catch( e ) {
                      console.log(e);
                    };
                }
          });
        },
    };
    me.open();
    return me
};
var ws = _ws_reopen();
</script>
<style>
body {
    margin: 0px;
    padding: 0px;
    /* width: 100%; */
    /* height: 100vh; */
    overflow: hidden;
}
.container {
  width: 100%;
  height: 100vh;
}
.row {
  width: 100%;
  display: flex;
  flex: 1;
  flex-direction: row;
  height: 100vh;
    overflow: hidden;
}

.column {
  width: 50%;
  overflow: auto;
  /* flex: 1; */
}

td.num { text-align: right };

thead {
    position: sticky;
    top: 0;
}

</style>
</head>
<body>
    <div id="container" class="container">
    <div id="row" class="row">
    <div class="column" style="overflow: auto;">
% for my $res (@$results) {
%= include 'query', res => $res;
% }
</div><iframe name="detail" class="column"></iframe>
</body>
</html>

@@query.html.ep
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
