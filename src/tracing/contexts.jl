abstract type AbstractContext{V,L,C} end

# This allows `DataType` arguments to be passed around within
# contexts without incurring an inference specialization penalty.
struct TypeArg{T} end

macro defcontext(C)
    return esc(quote
        struct $C{V,L} <: $Cassette.AbstractContext{V,L,$(Expr(:quote, C))}
            value::V
        end
        Base.@inline $C(value::V) where {V} = $C{V,1}(value)
        Base.@inline $C(value::$Cassette.AbstractContext) = $Cassette.construct_nested_context($C, value)
        Base.@inline $Cassette.box(c::$C, value) = $C(value)
        Base.@inline $Cassette.box(c::$C, ::Type{T}) where {T} = $C($TypeArg{T}())
        Base.@inline $Cassette.box(c::$C{<:Any,L}, x::$C{<:Any,L}) where {L} = x
    end)
end

@generated function construct_nested_context(::Type{C}, value::AbstractContext{<:Any,L}) where {C,L}
    return quote
        $(Expr(:meta, :inline))
        C{typeof(value),$(L+1)}(value)
    end
end

@inline box() = error("this stub only exists to be extended by Cassette.@defcontext")

@inline unbox(x) = x
@inline unbox(c::AbstractContext) = c.value
@inline unbox(::AbstractContext{TypeArg{T}}) where {T} = T

@inline unbox(c::AbstractContext, x) = x
@inline unbox(c::AbstractContext{<:Any,L,C}, x::AbstractContext{<:Any,L,C}) where {L,C} = unbox(x)

@inline unboxcall(c::AbstractContext, f, args...) = call(x -> unbox(c, x), f , args...)