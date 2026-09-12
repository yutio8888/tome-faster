module(..., package.seeall, class.make)

function _M:init(size)
    assert(size ~= 0, "error cannot have zero size cache")
    self.size = size
    self.index = 0
end

function _M:append(table)
    for _, v in ipairs(table) do
        self.index = math.max(1, (self.index + 1) % self.size)
        self[self.index] = v
    end
end

function _M:offer(v)
    self.index = math.max(1, (self.index + 1) % self.size)
    self[self.index] = v
end

function _M:peek()
    return self.index, self[self.index]
end

function _M:peekOldest()
    if #self == 0 then
        return 0, nil
    end
    local old_index = math.max(1, (self.index + 1) % #self)
    return old_index, self[old_index]
end

function _M:enumerate(nb)
    nb = nb or self.size
    if nb <= 0 then return {} end
    local ret = {}
    local count = 0
    for index = self.index + 1, #self do
        ret[#ret + 1] = self[index]
        count = count + 1
        if count >= nb then return ret end
    end
    for index = 1, self.index do
        ret[#ret + 1] = self[index]
        count = count + 1
        if count >= nb then return ret end
    end
    return ret
end