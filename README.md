# Cassette

## DISCLAIMER

Cassette is still in development. At any given time, the implementation might be ugly,
buggy, incomplete, slow, and/or untested. You may not be able to reproduce any examples
given in the README. Cassette relies on new reflection features and compiler performance
improvements (e.g. fixing JuliaLang/julia#5402) that will hopefully land in Julia 1.0.
Until an initial version of Cassette is released, I can't guarantee that Cassette's
`master` branch won't rely on some weird custom version of Julia.

Also note that whenever I show macro-expanded/lowered code in this README, I've cleaned up
the output for readability (e.g. removing metadata like line number info).

## Introduction

### What is Cassette?

Cassette is a Julia package that provides...

- ...a *contextual call interceptor*.
- ...a *contextual metadata propagation* framework.
- ...a *computation graph framework* with two graph implementations (one for optimized for
a dynamic regime, the other for a static regime).

Cassette targets downstream package developers, not Julia end-users. Cassette's API and
documentation expects downstream developers to have a solid understanding of Julia's type
system, metaprogramming facilities, and dispatch mechanism.

Downstream applications for Cassette include automatic differentiation, interval constraint
programming, dynamic code analysis (e.g. profiling, `rr`-style debugging, etc.), JIT
transpilation to different backends, automatic parallelization/rescheduling, memoization,
automatic preallocation, and code fuzzing.

### Why "Cassette"?

Because the package enables you to "overdub" Julia "tapes" with new behaviors :D

## Some Details

### Cassette's Contextual Call Interceptor

First and foremost, "contextual call intercepting" is a phrase I just made up. If anybody
knows of any existing terms in the literature for Cassette's weird brand of execution
tracing, feel free to let me know.

Cassette can instrument your Julia code in order to intercept native Julia method calls as
they occur during program execution. Which calls are intercepted and what actually happens
when interception occurs are both defined with respect to a Cassette "context", which is
itself defined by Cassette users.

#### Contextual code execution

The easiest way to understand Cassette's call interception is via an example:

```julia
julia> using Cassette: @context, @hook, Enter, unwrap

julia> @context MyCtx

julia> @hook MyCtx @ctx(f)(args...) = println("calling ", unwrap(f), args)

julia> function rosenbrock(x::Vector{Float64})
                  a = 1.0
                  b = 100.0
                  result = 0.0
                  for i in 1:length(x)-1
                      result += (a - x[i])^2 + b*(x[i+1] - x[i]^2)^2
                  end
                  return result
              end
rosenbrock (generic function with 1 method)

julia> Enter(MyCtx(rosenbrock))(rand(2))
calling length([0.896566, 0.742933],)
calling arraylen([0.896566, 0.742933],)
calling colon(1, 1)
calling UnitRange{Int64}(1, 1)
calling start(1:1,)
calling oneunit(Int64,)
calling Int64(1,)
calling oftype(2, 1)
calling convert(Int64, 1)
calling !(false,)
calling not_int(false,)
calling next(1:1, 1)
calling convert(Int64, 1)
calling +(1, 1)
calling add_int(1, 1)
calling getindex([0.896566, 0.742933], 1)
calling Core.arrayref([0.896566, 0.742933], 1)
calling Base.literal_pow(^, 0.10343429038286822, Val{2}())
calling *(0.10343429038286822, 0.10343429038286822)
calling mul_float(0.10343429038286822, 0.10343429038286822)
calling +(1, 1)
calling add_int(1, 1)
calling getindex([0.896566, 0.742933], 1)
calling Core.arrayref([0.896566, 0.742933], 1)
calling Val{2}()
calling -(0.7429328146031335, 0.8038300716612711)
calling sub_float(0.7429328146031335, 0.8038300716612711)
calling Val{2}()
calling *(100.0, 0.0037084759172048816)
calling mul_float(100.0, 0.0037084759172048816)
calling +(0.0, 0.38154624414749566)
calling add_float(0.0, 0.38154624414749566)
calling !(true,)
calling not_int(true,)
0.38154624414749566
```

So, what actually happened here? Here's an overly-detailed, step-by-step breakdown.

##### 1. We defined a context

We defined a new Cassette context called `MyCtx` using the `@context` macro. This
macro merely defines a normal Julia `struct` with the name `MyCtx`, and overloads a
couple of Cassette's internal methods with this new type. To prove that, let's expand the
call to the `@context` macro. Don't get hung up on the details here - I just want to prove
that nothing diabolical is going on. Here's the expanded code, with some manual clean-up
for readability:

```julia
julia> @macroexpand @context MyCtx
quote
    struct MyCtx{T, F} <: Cassette.AbstractContext{:MyCtx, T, F}
        tag::Cassette.Tag{:MyCtx, T}
        func::F
        MyCtx(tag::Cassette.Tag{:MyCtx, T}, func::F) where {T, F} = new{T, F}(tag, func)
        MyCtx(tag::Cassette.Tag{:MyCtx, T}, func::Type{F}) where {T, F} = new{T, Type{F}}(tag, func)
        MyCtx(tag::Cassette.Tag{:MyCtx, T}, func::Cassette.AbstractContext) where T = error("cannot nest contexts without an Enter barrier")
    end
    MyCtx(f) = MyCtx(Cassette.Tag(Val{:MyCtx}(), f), f)
    Cassette._wrap(ctx::MyCtx, f::F) where F = MyCtx(ctx.tag, f)
    Cassette._hook(ctx::MyCtx, args...) = nothing
    Cassette._isprimitive(ctx::MyCtx, args...) = Val(false)
    (f::MyCtx{##TagTypeVar#778})(args...) where ##TagTypeVar#778 = Cassette.unwrapcall(f, args...)
end
```

##### 2. We defined a hook

Next, we defined a Cassette "hook" for `MyCtx` method calls via the `@hook` macro.
Cassette will call this hook every time it intercepts a method call. Once again, let's
see what's really going on by macro-expanding the code (and once again, I've cleaned
this up a little bit for readability):

```julia
julia> @macroexpand @hook MyCtx @ctx(f)(args...) = println("calling ", unwrap(f), args)
quote
    function Cassette._hook(f::MyCtx{##TagTypeVar#779}, args...) where ##TagTypeVar#779
        println("calling ", unwrap(f), args)
    end
end
```

As you can see, this macro overrides the `Cassette._hook` method originally defined by the
`@context` macro. You may also notice that the arguments are also available for dispatch;
let's leverage this to add more specialized hooks:

```julia
julia> @hook MyCtx @ctx(f)(args::Number...) = println("OH WOW, NUMERIC ARGUMENTS! ", unwrap(f), args)

julia> Enter(MyCtx(rosenbrock))(rand(2))
calling length([0.862201, 0.591748],)
calling arraylen([0.862201, 0.591748],)
OH WOW, NUMERIC ARGUMENTS! colon(1, 1)
OH WOW, NUMERIC ARGUMENTS! UnitRange{Int64}(1, 1)
calling start(1:1,)
calling oneunit(Int64,)
OH WOW, NUMERIC ARGUMENTS! Int64(1,)
OH WOW, NUMERIC ARGUMENTS! oftype(2, 1)
calling convert(Int64, 1)
OH WOW, NUMERIC ARGUMENTS! !(false,)
OH WOW, NUMERIC ARGUMENTS! not_int(false,)
calling next(1:1, 1)
calling convert(Int64, 1)
OH WOW, NUMERIC ARGUMENTS! +(1, 1)
OH WOW, NUMERIC ARGUMENTS! add_int(1, 1)
calling getindex([0.862201, 0.591748], 1)
calling Core.arrayref([0.862201, 0.591748], 1)
calling Base.literal_pow(^, 0.13779926032137668, Val{2}())
OH WOW, NUMERIC ARGUMENTS! *(0.13779926032137668, 0.13779926032137668)
OH WOW, NUMERIC ARGUMENTS! mul_float(0.13779926032137668, 0.13779926032137668)
OH WOW, NUMERIC ARGUMENTS! +(1, 1)
OH WOW, NUMERIC ARGUMENTS! add_int(1, 1)
calling getindex([0.862201, 0.591748], 1)
calling Core.arrayref([0.862201, 0.591748], 1)
OH WOW, NUMERIC ARGUMENTS! Val{2}()
OH WOW, NUMERIC ARGUMENTS! -(0.5917475134530223, 0.7433901155023652)
OH WOW, NUMERIC ARGUMENTS! sub_float(0.5917475134530223, 0.7433901155023652)
OH WOW, NUMERIC ARGUMENTS! Val{2}()
OH WOW, NUMERIC ARGUMENTS! *(100.0, 0.02299547875629537)
OH WOW, NUMERIC ARGUMENTS! mul_float(100.0, 0.02299547875629537)
OH WOW, NUMERIC ARGUMENTS! +(0.0, 2.3185365117746555)
OH WOW, NUMERIC ARGUMENTS! add_float(0.0, 2.3185365117746555)
OH WOW, NUMERIC ARGUMENTS! !(true,)
OH WOW, NUMERIC ARGUMENTS! not_int(true,)
2.3185365117746555
```

##### 3. We contextually executed some code

Finally, we recursively intercepted all method calls within `rosenbrock`. At the base cases
- called "primitives" in Cassette-lingo - we called the `(f::MyCtx)(args...)` method
automatically defined by `@context`. Note that, as a fallback, Cassette always considers
`Core` methods and unreflectable methods primitives.

To illustrate what's actually going on, let's look at the lowered code for a normal `rosenbrock`
call and compare it to the lowered code for a call to `Enter(MyCtx(rosenbrock))`:

```julia
julia> @code_lowered rosenbrock(rand(2))
CodeInfo(:(begin
        a = 1.0
        b = 100.0
        result = 0.0
        SSAValue(0) = (Main.colon)(1, (Main.length)(x) - 1)
        #temp# = (Base.start)(SSAValue(0))
        10:
        unless !((Base.done)(SSAValue(0), #temp#)) goto 19
        SSAValue(1) = (Base.next)(SSAValue(0), #temp#)
        i = (Core.getfield)(SSAValue(1), 1)
        #temp# = (Core.getfield)(SSAValue(1), 2)
        result = result + ((Base.literal_pow)(Main.^, a - (Main.getindex)(x, i), ((Core.apply_type)(Base.Val, 2))()) + b * (Base.literal_pow)(Main.^, (Main.getindex)(x, i + 1) - (Base.literal_pow)(Main.^, (Main.getindex)(x, i), ((Core.apply_type)(Base.Val, 2))()), ((Core.apply_type)(Base.Val, 2))()))
        goto 10
        19:
        return result
    end))

julia> @code_lowered Enter(MyCtx(rosenbrock))(rand(2))
CodeInfo(:(begin
        nothing
        a = 1.0
        b = 100.0
        result = 0.0
        SSAValue(0) = ((Cassette.Intercept)(#self#, Main.colon))(1, ((Cassette.Intercept)(#self#, Main.length))(x) - 1)
        #temp# = ((Cassette.Intercept)(#self#, Base.start))(SSAValue(0))
        10:
        unless ((Cassette.Intercept)(#self#, Base.!))((Base.done)(SSAValue(0), #temp#)) goto 19
        SSAValue(1) = ((Cassette.Intercept)(#self#, Base.next))(SSAValue(0), #temp#)
        i = (Core.getfield)(SSAValue(1), 1)
        #temp# = (Core.getfield)(SSAValue(1), 2)
        result = ((Cassette.Intercept)(#self#, Main.+))(result, ((Cassette.Intercept)(#self#, Base.literal_pow))(Main.^, a - ((Cassette.Intercept)(#self#, Main.getindex))(x, i), ((Core.apply_type)(Base.Val, 2))()) + ((Cassette.Intercept)(#self#, Main.*))(b, (Base.literal_pow)(Main.^, ((Cassette.Intercept)(#self#, Main.-))((Main.getindex)(x, ((Cassette.Intercept)(#self#, Main.+))(i, 1)), (Base.literal_pow)(Main.^, ((Cassette.Intercept)(#self#, Main.getindex))(x, i), ((Cassette.Intercept)(#self#, (Core.apply_type)(Base.Val, 2)))())), ((Cassette.Intercept)(#self#, (Core.apply_type)(Base.Val, 2)))())))
        goto 10
        19:
        return result
    end))
```

The lowered code for `Enter(MyCtx(rosenbrock))` is the same as the lowered code for
`rosenbrock`, but every callable object that is being called has been wrapped in the
`Cassette.Intercept` type, which is then called instead. Internally, the definition
of `Cassette.Intercept` and its execution behavior looks similar to the following:

```julia
struct Enter{C<:AbstractContext}
    context::C
end

@generated function (::Enter)(args...)
    # I'm not going to show this because it's pretty complicated, but
    # what this does is run the underlying contextualized method call
    # with all subcalls wrapped in `Intercept`
end

struct Intercept{C<:AbstractContext}
    context::C
end

Intercept(e::Enter, f) = Intercept(_wrap(e.context, f))

Intercept(e::Enter) = Intercept(e.context)

function (i::Intercept)(args...)
    hook(i.context, args...)
    return execute(i, args...)
end

execute(i::Intercept, args...) = execute(isprimitive(i.context, args...), i, args...)
execute(::Val{true}, i::Intercept, args...) = i.context(args...)
execute(::Val{false}, i::Intercept, args...) = Enter(i.context)(args...)
```

#### Contextual primitives

Earlier in the README, I mentioned primitives:

> At the base cases - called "primitives" in Cassette-lingo - we called the `(f::MyCtx)(args...)`
method automatically defined by `@context`. Note that, as a fallback, Cassette always considers
`Core` methods and unreflectable methods primitives.

Context creators can also define their own primitives and primitive behaviors. For this
purpose, Cassette provides three macros: `@contextual`, `@isprimitive`, and `@primitive`.

Let's start with `@contextual`. Here's a macro-expanded example of `@contextual` in action:

```julia
julia> @macroexpand @contextual MyCtx @ctx(f)(args...) = Cassette.unwrapcall(f, args...)
quote
    function (f::MyCtx{##TagTypeVar#780})(args...) where ##TagTypeVar#780
        # call `f(args...)`, but contextually unwrap `f` and its arguments first
        return Cassette.unwrapcall(f, args...)
    end
end
```

If you have sharp eyes and an insanely good memory, you might recall that this is
the fallback method definition that is defined by `@context`.

### Cassette's Contextual Metadata Propagation Framework

TODO

### Cassette's Computation Graph Framework

TODO
