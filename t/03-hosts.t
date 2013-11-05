# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * 7;

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_upstream 1m;

    init_by_lua '
        socket_upstream = require("resty.socket-upstream")

        local dict = ngx.shared["test_upstream"]
        dict:delete("pools")

        upstream, configured = socket_upstream:new("test_upstream")

        upstream:createPool({id = "primary", timeout = 100})
        ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Cannot add host to non-existent pool
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /1 {
        content_by_lua '
            local ok, err upstream:addHost("foobar", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, keepalive = 256, weight = 10 })
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /1
--- errorcode: 200

=== TEST 2: Mark single host down after 3 fails
--- http_config eval: $::HttpConfig
--- config
    location = /2 {
        content_by_lua '
            upstream:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, keepalive = 256, weight = 10 })

            -- Simulate 3 connection attempts
            for i=1,3 do
                upstream:connect()
                upstream:postProcess()
            end

            pools = upstream:getPools()

            if pools.primary.hosts.a.up then
                ngx.status = 500
                ngx.say("FAIL")
            else
                ngx.status = 200
                ngx.say("OK")
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /2
--- response_body
OK

=== TEST 3: Mark round_robin host down after 3 fails
--- http_config eval: $::HttpConfig
--- config
    location = /3 {
        content_by_lua '
            upstream:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, keepalive = 256, weight = 9999 })
            upstream:addHost("primary", { id="b", host = ngx.var.server_addr, port = ngx.var.server_port+1, keepalive = 256, weight = 1 })

            -- Simulate 3 connection attempts
            for i=1,3 do
                upstream:connect()
                upstream:postProcess()
            end

            pools = upstream:getPools()

            if pools.primary.hosts.a.up then
                ngx.say("FAIL")
                ngx.status = 500
            else
                ngx.say("OK")
                ngx.status = 200
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /3
--- response_body
OK

=== TEST 4: Mixed specific and implied host IDs
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /4 {
        content_by_lua '

            upstream:addHost("primary", { host = ngx.var.server_addr, port = ngx.var.server_port, keepalive = 256, weight = 1 })
            upstream:addHost("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, keepalive = 256, weight = 1 })
            upstream:addHost("primary", { host = ngx.var.server_addr, port = ngx.var.server_port, keepalive = 256, weight = 1 })
            upstream:addHost("primary", { id="foo", host = ngx.var.server_addr, port = ngx.var.server_port, keepalive = 256, weight = 1 })

            local pools, err = upstream:getPools()
            local ids = {}
            for k,v in pairs(pools.primary.hosts) do
                table.insert(ids, tostring(k))
            end
            table.sort(ids)
            for k,v in ipairs(ids) do
                ngx.say(v)
            end
        ';
    }
--- request
GET /4
--- response_body
1
2
a
foo
