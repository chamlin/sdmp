#!/usr/bin/perl -w
use strict;
use File::Spec;
use File::Path qw(make_path);
use Data::Dumper;

$| = 1;

my @headers = (
    'App Server Status',
    'Forest Status',
    'Trigger Definitions',
    'CPF Domains',
    'CPF Pipelines',
    'SQL Schemas',
    'SQL Views',
    'XML Schemas',
    'Host Status',
    'Configuration',
    'Database Topology',
);

my $self = {
    patterns => [
        [ section_header => '^(' . join ('|', @headers) . ')' ],
        [ bigsep => '^\s?%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%' ],
        [ sep    => '^\s?#################################################################' ],
        [ subsep => '^\s?=================================================================' ],
        [ empty  => '^\s?$' ],
        [ indented   => '^\s+\S' ],
        [ end    => '^<\/([^\s>]+)' ],
        [ start  => '^<([^\s>]+)' ],
        [ text   => '^[\S\s]' ], # This covers (?) junk like nbsp, etc.?
    ],
    support_case => 99999, 
    fns => {
        dump_state => sub { my ($self) = @_; print STDERR '[', join (', ', @{$self->{state}}), "]\n"; },
        save_line => sub { my ($self) = @_; push @{$self->{blocks}[0]{content}}, $self->{input}{line}; },
        push_state => sub { my ($self, $state) = @_; push @{$self->{state}}, $state; },
        pop_state => sub { my ($self) = @_; return pop @{$self->{state}}; },
        get_state => sub { my ($self) = @_; return $self->{state}[$#{$self->{state}}]; },
        replace_state => sub { my ($self, $state) = @_; pop @{$self->{state}}; push @{$self->{state}}, $state; },
        header_reset => sub {
                my ($self) = @_;
                $self->{fns}{pop_state}->($self);
                push @{$self->{buffer}}, $self->{input}{line};
        },
        start_xml => sub {
                my ($self) = @_;
                $self->{fns}{push_state}->($self, 'xml');
                unshift @{$self->{blocks}}, { type => 'xml', header => $self->{input}{value}, start_line => $self->{input}{line_number}, content => [] };
                $self->{fns}{save_line}->($self);
        },
    },
    actions => {
        body => {
           section_header => sub {
                my ($self) = @_;
                my $section = lc $self->{input}{value};
                $section =~ s/ /_/g;
                unshift @{$self->{blocks}}, { type => 'section', header => $section, start_line => $self->{input}{line_number}, content => [] };
                if ($section eq 'app_server_status' | $section eq 'host_status' | $section eq 'log_files' | $section eq 'database_topology') {
                    $self->{fns}{push_state}->($self, $section);
                    if ($section eq 'database_topology') {
                        # this so we have a content block separat from the section header
                        unshift @{$self->{blocks}}, { type => 'text', header => 'database_topology', start_line => $self->{input}{line_number}, content => [] };
                    }
                } else {
                    # these are pretty general
                    $self->{fns}{push_state}->($self, 'per_db_dump');
                }
            },
            empty => sub { },
            bigsep => sub { },
            subsep => sub { },
            sep => sub { },
            start => sub { my ($self) = @_; $self->{fns}{start_xml}->($self); },
            text => sub {
                my ($self) = @_;
                if ($self->{input}{line} =~ /^Hostname:\s+(.*)/) {
                    unshift @{$self->{blocks}}, { type => 'host', header => $1, start_line => $self->{input}{line_number}, content => [] };
                    $self->{fns}{push_state}->($self, 'save_text');
                } else {
                    $self->{actions}{default}($self);
                }
            },
        },
        config => {
            text => sub {
                my ($self) = @_;
                if ($self->{input}{line} =~ /^\w+\.xml$/) {
                    # start new block
                    unshift @{$self->{blocks}}, { type => 'config', header => $self->{input}{line}, start_line => $self->{input}{line_number}, content => [] };
                } elsif ($self->{input}{line} =~ /^Validation results/) {
                    $self->{blocks}[0]{validation} = $self->{input}{line};
                } else {
                    $self->{actions}{default}($self);
                }
            },
            # should be a block started with filename.  check?
            start => sub { my ($self) = @_; $self->{fns}{start_xml}->($self); },
            subsep => sub { },
            empty => sub { my ($self) = @_; $self->{fns}{pop_state}->($self); }
        },
        database_topology => {
            indented => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            text => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            subsep => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            empty => sub { my ($self) = @_; $self->{fns}{pop_state}->($self); }
        },
        per_db_dump => {
            section_header => sub { my ($self) = @_; $self->{fns}{header_reset}->($self) },
            subsep => sub { },
            text => sub { my ($self) = @_;
                unshift @{$self->{blocks}}, { type => 'db_block', header => $self->{input}{line}, start_line => $self->{input}{line_number}, content => [] };
            },
            start => sub { my ($self) = @_; $self->{fns}{start_xml}->($self); },
            # empty => sub { my ($self) = @_; $self->{fns}{pop_state}->($self); },
            empty => sub { },
            bigsep => sub { my ($self) = @_; $self->{fns}{pop_state}->($self); }
        },
        app_server_status => {
            section_header => sub { my ($self) = @_; $self->{fns}{header_reset}->($self) },
            text => sub {
                my ($self) = @_;
                my $line = $self->{input}{line};
                if ($line =~ /^Group:/) { 
                    unshift @{$self->{blocks}}, { type => 'app_server', header => $self->{input}{line}, start_line => $self->{input}{line_number}, content => [] };
                } else {
                    $self->{actions}{default}($self);
                }
            },
            empty => sub { },
            bigsep => sub { },
            subsep => sub { },
            sep => sub { },
            start => sub { my ($self) = @_; $self->{fns}{start_xml}->($self); },
        },
        host_status => {
            text => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            subsep => sub { my ($self) = @_; $self->{fns}{pop_state}->($self); },
        },
        save_text => {
            section_header => sub { my ($self) = @_; $self->{fns}{header_reset}->($self) },
            text => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            empty => sub { },
            bigsep => sub { },
            subsep => sub { },
            sep => sub { },
        },
        section_head => {
            section_header => sub { my ($self) = @_; $self->{fns}{header_reset}->($self); },
            text => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            bigsep => sub { my ($self) = @_; $self->{fns}{pop_state}->($self); },
        },
        xml => {
            end => sub {
                my ($self) = @_;
                my $start = $self->{blocks}[0]{header};
                my $end = $self->{input}{value};
                if ($end =~ /certificate$/) {
                    # certs sometimes wacky; just take line
                    $self->{fns}{save_line}->($self);
                } elsif ( $start ne $end) {
                    #print STDERR "Warning: start/end mismatch $start/$end.\n";
                    # but go ahead and hope for best
                    $self->{fns}{save_line}->($self);
                } else {
                    $self->{fns}{save_line}->($self);
                    $self->{fns}{pop_state}->($self);
                }
            },
            # let's see how this goes
            # comments in pipelines, for example, can create empty lines in xml
            # uggh, schemas, etc., have all kinds of stuff
            indented => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            empty => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            text => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            # just something that should be indented?
            start => sub { my ($self) = @_; $self->{fns}{save_line}->($self); },
            text_XXX => sub {
                my ($self) = @_;
                my $current_block_header = $self->{blocks}[0]{header};
                if ($current_block_header eq 'hosts' || $current_block_header eq 'clusters') {
                    # could be, the cert can be wacky
                    $self->{fns}{save_line}->($self);
                } else {
                    print STDERR "text unexpected.\n";
                    $self->{actions}{default}($self);
                }
            },
        },
        default => sub { my ($self) = @_; die "Died in ", $self->{fns}{get_state}->($self), " with class $self->{input}{class} on line $self->{input}{line_number}.\n" . Dumper $self; },
    },
    state => [ 'body', 'save_text' ],
    blocks => [ { type => 'head', header => 'report_head', start_line => 1, content => [] } ],
    buffer => [],
    # line, line_number, state
};

for my $pattern (@{$self->{patterns}}) {
    push @{$self->{regex}}, [ $pattern->[0], qr/$pattern->[1]/ ];
}

my $file = 'support-request-go.xqy';
open (my $in, '<:crlf', $file);
$self->{IN} = $in;

while (1) {
    my $line = get_line ($self);
    unless (defined ($line)) { last }
    # print STDERR ">>>>> |$line|\n";
    #$self->{fns}{dump_state}->($self);
    $self->{input}{line} = $line;
    classify_line ($self);
    take_action ($self);
}

$self->{blocks} = [reverse @{$self->{blocks}}];

unless (-d "./Support-Dump") { mkdir "./Support-Dump" }

foreach my $block (@{$self->{blocks}}) {
    if    ($block->{header} eq 'report_head')   { dump_request_header ($self, $block) }
    elsif ($block->{type} eq 'section')  { $self->{current_section} = $block->{header} }
    elsif ($block->{type} eq 'db_block')  { $self->{current_db_block} = $block->{header} }
    elsif ($block->{type} eq 'app_server')      {
        my ($group, $appserver, $host) = $block->{header} =~ /Group: ([^,]+), Appserver: ([^,]+), Host: ([^,]+)/;
        unless ($host) { print STDERR "Can't extract values from appserver status header |$block->{header}|.\n" }
        @{$self->{'current_host', 'current_appserver', 'current_group'}} = ($host, $appserver, $group);
    } elsif ($block->{type} eq 'host') {
        dump_host_details ($self, $block);
        $self->{current_host} = $block->{header};
    } elsif ($block->{type} eq 'xml' && $self->{current_section} eq 'configuration')  {
        my $host = $self->{current_host};
        my $host_id = $self->{host_id_map}{$host};
        $host =~ s/\./_/g;
        my $path = "./Support-Dump/$self->{host_group_map}{$host_id}/$host/Configuration/$block->{header}.xml";
        ensure_dirs ($path);
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'host-status')  {
        my $host = $self->{current_host};
        my $host_id = $self->{host_id_map}{$host};
        $host =~ s/\./_/g;
        my $path = "./Support-Dump/$self->{host_group_map}{$host_id}/$host/Host-Status.xml";
        ensure_dirs ($path);
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'server-status')  {
        my ($host, $appserver, $group) = @{$self->{'current_host', 'current_appserver', 'current_group'}};
        my $path = app_server_path ($group, $appserver, $host);
        dump_lines_to_path ($block->{content}, $path);
        # update host_id -> host map
        my $host_id = extract_element_value ($block, 'host-id');
        if ($host_id)  {
            $self->{host_name_map}{$host_id} = $host;
            $self->{host_id_map}{$host} = $host_id;
            $self->{host_group_map}{$host_id} = $group;
        } else {
            warn "Couldn't find host-id in @{$block->{content}}.\n";
        }
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'forest-status')  {
        my $forest_id = extract_element_value ($block, 'forest-id');
        my $forest_name = extract_element_value ($block, 'forest-name');
        my $host_id = extract_element_value ($block, 'host-id');
        $self->{forest_host_map}{$forest_id} = $host_id;
        $self->{forest_name_map}{$forest_id} = $forest_name;
        my $path = forest_path ($self, $forest_id) . '/Forest-Status.xml';
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'forest-counts')  {
        my $forest_id = extract_element_value ($block, 'forest-id');
        my $path = forest_path ($self, $forest_id) . '/Forest-Counts.xml';
        dump_lines_to_path ($block->{content}, $path);
    # TODO handle prefixes somehow?
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'trgr:trigger')  {
        my $trigger_name = extract_element_value ($block, 'trgr:trigger-name');
        my $path = "./Support-Dump/Triggers/$self->{current_db_block}/$trigger_name.xml";
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'dom:domain')  {
        my $domain_name = extract_element_value ($block, 'dom:domain-name');
        my $path = "./Support-Dump/Domains/$self->{current_db_block}/$domain_name.xml";
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'dom:configuration')  {
        my $config_id = extract_element_value ($block, 'dom:config-id');
        my $path = "./Support-Dump/Domains/$self->{current_db_block}/config-$config_id.xml";
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'p:pipeline')  {
        my $pipeline_name = extract_element_value ($block, 'p:pipeline-name');
        my $path = "./Support-Dump/Pipelines/$self->{current_db_block}/$pipeline_name.xml";
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'xml' && $block->{header} eq 'xs:schema')  {
        my $pipeline_name = extract_element_ns ($block, 'p:pipeline-name');
        my $path = "./Support-Dump/Schemas/$self->{current_db_block}/$pipeline_name.xml";
        dump_lines_to_path ($block->{content}, $path);
    } elsif ($block->{type} eq 'text' && $block->{header} eq 'database_topology')  {
        dump_lines_to_path ($block->{content}, './Support-Dump/Database-Topology.txt');
    } elsif ($block->{header} eq 'forest_status')  {
        # nada
    } elsif ($block->{header} eq 'app_server_status')  {
        # nada
    }
    else { warn "what is $block->{header} start line $block->{start_line}.\n"; }
}


print STDERR "finished reading.\n";

print STDERR Dumper $self;

sub forest_path {
    my ($self, $forest_id) = @_;
    my $forest_name = $self->{forest_name_map}{$forest_id};
    my $host_id = $self->{forest_host_map}{$forest_id};
    my $group = $self->{host_group_map}{$host_id};
    my $host_name = get_host_name ($self, $host_id);
    $host_name =~ s/\./_/g;
    my $dir = "./Support-Dump/$group/$host_name/Forests/$forest_name";
    unless (-d $dir)  { make_path $dir }
    return "$dir";
}

sub get_host_name {
    my ($self, $host_id) = @_;
    my $host_name = $host_id ? $self->{host_name_map}{$host_id} : 'unknown_host';
    warn "Couldn't find resolve host-id $host_id.\n" if ($host_name eq 'unknown_host');
    return $host_name;
}

sub extract_element_ns {
    my ($block, $element) = @_;
    my $ns = int (rand (10000));
    if ($block->{content}[0] =~ /xmlns='([^']+)'/ || $block->{content}[0] =~ /xmlns="([^"]+)"/) {
        $ns = $1
    }
    $ns =~ tr/:\//-_/;
    return $ns;
}

sub extract_element_value {
    my ($block, $element) = @_;
    my $pattern = "<$element>(.+)<\\/$element>";
    my $value = undef;
    foreach my $line (@{$block->{content}}) {
        if ($line =~ /$pattern/) { $value = $1; last }
    }
    warn "Couldn't get $element value from @{$block->{content}}.\n" unless ($value);
    return $value;
}

sub ensure_dirs {
    my ($full) = @_;
    my ($volume,$directories,$file) = File::Spec->splitpath ($full);
    unless (-d $directories) { make_path $directories }
}

sub dump_lines_to_path {
    my ($lines, $path) = @_;
    ensure_dirs ($path);
    open (my $fh, '>', $path) || die "Can't open $path.\n";
    foreach my $line (@$lines)  { print $fh $line, "\n" }
    close $fh;
}

sub app_server_path {
    my ($group, $appserver, $host) = @_;
    $host =~ s/\./_/g;
    my $path = "./Support-Dump/$group/$host/App-Servers/$appserver-Status.xml";
    ensure_dirs ($path);
    return $path
}

sub dump_request_header {
    my ($self, $block) = @_;
    my $content = '<Support-Request xmlns="http://marklogic.com/support/meta">' . "\n";
    $content .= "<Support-Case>$self->{support_case}</Support-Case>\n";
    foreach my $line (@{$block->{content}}) {
        my ($key, $value) = $line =~ /^([^:]+?):\s+(.*)/;
        unless ($key && $value)  { print STDERR "Unknown header line |$line|\n" }
        $key =~ s/ /-/g;
        $content .= "<$key>$value</$key>\n";
    }
    $content .= "</Support-Request>\n";
    open my $fh, '>', "./Support-Dump/Support-Request.xml";
    print $fh $content;
    close $fh;
};


sub dump_host_details {
    my ($self, $block) = @_;
    my $content = '<Host-Details xmlns="http://marklogic.com/host/details">' . "\n";
    foreach my $line (@{$block->{content}}) {
        my ($key, $value) = $line =~ /^([^:]+?):\s+(.*)/;
        unless ($key && $value)  { print STDERR "Unknown header line |$line|\n" }
        $key =~ s/ /-/g;
        $content .= "<$key>$value</$key>\n";
    }
    $content .= "</Host-Details>\n";
    my $host = $block->{header};
    my $host_id = $self->{host_id_map}{$host};
    $host =~ s/\./_/g;
    my $path = "./Support-Dump/$self->{host_group_map}{$host_id}/$host/Host-Details.xml";
    ensure_dirs ($path);
    open my $fh, '>', $path;
    print $fh $content;
    close $fh;
};



sub get_line {
    my ($self) = @_;
    my $line = pop @{$self->{buffer}};
    unless (defined ($line)) { $line = readline ($self->{IN}) }
    if (defined $line) { $line =~ s/\R//; }
    return $line;
}

sub take_action {
    my ($self) = @_;
    my $state = $self->{fns}{get_state}->($self);
    my ($class, $value, $line) = @{$self->{input}}{'class', 'value', 'line'};
    #print STDERR "$state.  $class ($value) --- $line\n";
    unless (exists $self->{actions}{$state}) {
        print STDERR Dumper $self;
        die "No such state $state at $self->{input}{line_number}.\n"
    }
    my $action = (@{$self->{actions}{$state}}{$class, 'default'});
    $action = $self->{actions}{$state}{$class};
    unless (defined $action) { 
        die "No action found for $state/$class at $self->{input}{line_number}.\n";
        $action = $self->{actions}{default};
    }
    $action->($self);
}

sub classify_line {
    my ($self) = @_;
    my ($line, $class, $value) = ($self->{input}{line});
    $self->{input}{line_number}++;
    foreach my $regex (@{$self->{regex}}) {
        
        my ($name, $regex) = @{$regex};
        if ($line =~ /$regex/) {
            $class = $name;
            $value = defined $1 ? $1 : '';
            last;
        }
    }
    unless (defined $class) { die "What class: $line\n"; }
    $self->{input}{class} = $class;
    $self->{input}{value} = $value;
}

sub elide {
    my ($self) = @_;
    foreach my $block (@{$self->{blocks}}) {
        if ($block->{header} eq 'server-status'
            || $block->{header} eq 'database_topology'
            || $block->{header} eq 'forest-counts'
            || $block->{type} eq 'xml' && $block->{header} eq 'forest-status'
           ) {
            $block->{content} = [
                $block->{content}[0],
                $block->{content}[-1],
            ];
        }
    }
}
