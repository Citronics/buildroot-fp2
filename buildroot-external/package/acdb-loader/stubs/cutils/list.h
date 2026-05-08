#ifndef _CUTILS_LIST_H
#define _CUTILS_LIST_H
struct listnode {
    struct listnode *next;
    struct listnode *prev;
};
#define node_to_item(node, container, member) \
    ((container *) (((char *) (node)) - __builtin_offsetof(container, member)))
#define list_declare(name) \
    struct listnode name = { .next = &(name), .prev = &(name), }
#define list_for_each(node, list) \
    for ((node) = (list)->next; (node) != (list); (node) = (node)->next)
#define list_for_each_reverse(node, list) \
    for ((node) = (list)->prev; (node) != (list); (node) = (node)->prev)
static inline void list_init(struct listnode *node) {
    node->next = node; node->prev = node;
}
static inline void list_add_tail(struct listnode *head, struct listnode *item) {
    item->next = head; item->prev = head->prev;
    head->prev->next = item; head->prev = item;
}
static inline void list_add_head(struct listnode *head, struct listnode *item) {
    item->next = head->next; item->prev = head;
    head->next->prev = item; head->next = item;
}
static inline void list_remove(struct listnode *item) {
    item->next->prev = item->prev; item->prev->next = item->next;
}
static inline int list_empty(struct listnode *list) {
    return list->next == list;
}
#define list_head(list) ((list)->next)
#define list_tail(list) ((list)->prev)
#endif
