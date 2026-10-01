class_name ActorState
extends RefCounted
## Base class for every actor state.
##
## `actor` is typed as `ActorBody` (the shared actor implementation) rather than
## the concrete `PlayerActor` / `BotActor`. That keeps the dependency graph
## one-way - states know the body, the body knows the states - so GDScript never
## has to resolve a cyclic `class_name` reference. Cyclic class references in
## Godot 4 fail as a cascade of unrelated "Could not resolve class" parse errors
## in files that are themselves fine, which is a miserable thing to debug.
##
## Constructors are deliberately argument-less: `ActorState.setup()` is called by
## `StateMachine.register()`. Parameterised `_init` on a class hierarchy that
## inner classes extend is a reliable source of constructor-forwarding surprises.

var machine: StateMachine
var actor: ActorBody
var id: StringName = &""
var time: float = 0.0          ## seconds spent in this state (updated by machine)
var entered_count: int = 0


func setup(m: StateMachine, a: ActorBody) -> void:
	machine = m
	actor = a


## Called when the state becomes current. `prev` is the state being left.
func enter(_prev: StringName, _data: Dictionary) -> void:
	pass


## Called just before leaving. Release anything transient here.
func exit() -> void:
	pass


## Logic, once per idle frame. Keep gameplay-independent work here.
func update(_delta: float) -> void:
	pass


## Physics, once per physics tick. Movement and hit queries belong here.
func physics(_delta: float) -> void:
	pass


## Whether `machine.change()` may leave this state. Non-interruptible states can
## still be overridden with `machine.force()`, which death and round resets use.
func interruptible() -> bool:
	return true


func label() -> String:
	return String(id)
