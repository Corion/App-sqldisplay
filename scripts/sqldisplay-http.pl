#!perl
use strict;
use warnings;

use Mojolicious::Lite;
use File::Basename 'dirname';

use lib '../DBIx-Spreadsheet/lib';
use DBIx::Spreadsheet;

use 5.020; # for signatures
use feature 'signatures';
no warnings 'experimental::signatures';

use Try::Tiny;
use PerlX::Maybe;
use YAML 'LoadFile';
use Encode 'decode';

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
$spreadsheet_file //= '/home/corion/Dokumente/Frankfurt Perlmongers e.V/Buchhaltung/Buchhaltung 2020/2020 Rechnungen.ods';
$query_file       //= dirname($spreadsheet_file) . '/dashboard.yml';

$watcher->instantiate_watcher(
# Add the spreadsheet here
# Add the query file here
# Add the html template here
# Maybe even add an SQLite file here?!
    directories => [dirname $spreadsheet_file, dirname $query_file],
);

$watcher->on('modify' => sub ( $self, $ev ) {
    if( $ev->path eq $spreadsheet_file ) {
        # reload the DB
        say "Reloading spreadsheet";
        reload_sheet( $spreadsheet_file );
    } elsif( $ev->path eq $query_file ) {
        # reload the queries
        say "Reloading queries";
        reload_queries( $query_file );
    }

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

sub notify_clients( @actions ) {
    my $clients = \%clients;
    for my $client_id (sort keys %$clients ) {
        my $client = $clients->{ $client_id };
        say "Notifying $client_id";
        for my $action (@actions) {
            # Convert path to what the client will likely have requested (duh)

            # These rules should all come from a config file, I guess
            #app->log->info("Notifying client $client_id of '$action->{name}' change to '$action->{path}'");
            use Data::Dumper; warn Dumper $action;
            $client->send({json => $action });
        };
    };
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
    @queries = LoadFile($file);
}

sub reload_sheet( $file ) {
    $sheet = DBIx::Spreadsheet->new( file => $file )
        or die "Couldn't read '$file'";
}

reload_queries( $query_file );
reload_sheet( $spreadsheet_file );

websocket sub($c) {
    my $client_id = add_client( $c );
};

get '/index' => sub( $c ) {
    # rerun all queries
    my @results = run_queries( @queries );
    $c->stash( results => \@results );
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
              var {path, type, selector, attr, str} = JSON.parse(msg.data)
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
td.num { text-align: right };
</style>
</head>
<body>
% for my $res (@$results) {
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
            <td class="<%= $class %>"><%= $r->{ $c->{name} } %></td>
        % }
        </tr>
    % }
    </tbody>
    </table>
% }
</body>
</html>
