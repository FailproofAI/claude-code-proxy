local method = ngx.req.get_method()
if method ~= "POST" and method ~= "PUT" and method ~= "PATCH" then
    return
end

ngx.req.read_body()
local body = ngx.req.get_body_data()

if body then
    local sid = body:match('"session_id"%s*:%s*"([^"]+)"')
    if sid then
        ngx.var.session_id = sid
    end
end
